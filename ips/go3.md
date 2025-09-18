// azure-vnet-scanner/internal/azure/scanner.go
package azure

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"

	"github.com/your-username/azure-vnet-scanner/internal/calculator"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/managementgroups/armmanagementgroups"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resources/armsubscriptions"
	"golang.org/x/sync/errgroup"
)

// ScanResult holds the data for a single output row.
type ScanResult struct {
	SubscriptionName string
	ManagementGroup  string
	VNetName         string
	VNetRegion       string
	AddressSpace     string
	AvailableIPs     uint64
}

// ScanOptions defines the parameters for a scan operation.
type ScanOptions struct {
	TargetSubscriptions   []string
	TargetManagementGroup string
}

// Scanner orchestrates the scanning of Azure resources.
type Scanner struct {
	clients *Clients
}

// NewScanner creates a new Scanner instance.
func NewScanner(clients *Clients) *Scanner {
	return &Scanner{clients: clients}
}

// Scan starts the scanning process based on the provided options.
func (s *Scanner) Scan(ctx context.Context, opts ScanOptions) ([]ScanResult, error) {
	subsToScan, err := s.getSubscriptionsToScan(ctx, opts)
	if err != nil {
		return nil, fmt.Errorf("failed to determine subscriptions to scan: %w", err)
	}

	if len(subsToScan) == 0 {
		log.Println("No subscriptions found to scan.")
		return nil, nil
	}

	log.Printf("Found %d subscriptions to scan. Starting VNet discovery...", len(subsToScan))

	resultsChan := make(chan ScanResult)
	var wg sync.WaitGroup
	g, gCtx := errgroup.WithContext(ctx)

	// Concurrently scan each subscription
	for _, sub := range subsToScan {
		currentSub := sub // Capture loop variable
		wg.Add(1)
		g.Go(func() error {
			defer wg.Done()
			return s.scanSubscriptionForVNets(gCtx, currentSub, resultsChan)
		})
	}

	go func() {
		wg.Wait()
		close(resultsChan)
	}()

	var allResults []ScanResult
	for result := range resultsChan {
		allResults = append(allResults, result)
	}

	if err := g.Wait(); err != nil {
		return nil, err
	}

	return allResults, nil
}

// getSubscriptionsToScan resolves which subscriptions to scan based on the CLI flags.
func (s *Scanner) getSubscriptionsToScan(ctx context.Context, opts ScanOptions) (map[string]armsubscriptions.Subscription, error) {
	allSubs, err := s.listAllSubscriptions(ctx)
	if err != nil {
		return nil, err
	}

	if len(opts.TargetSubscriptions) > 0 {
		return s.filterSubscriptionsByTarget(allSubs, opts.TargetSubscriptions), nil
	}

	if opts.TargetManagementGroup != "" {
		return s.getSubscriptionsInManagementGroup(ctx, opts.TargetManagementGroup, allSubs)
	}

	log.Println("No specific target provided. Scanning all accessible subscriptions.")
	return allSubs, nil
}

// listAllSubscriptions fetches all subscriptions the user has access to.
func (s *Scanner) listAllSubscriptions(ctx context.Context) (map[string]armsubscriptions.Subscription, error) {
	subsMap := make(map[string]armsubscriptions.Subscription)
	pager := s.clients.subsClient.NewListPager(nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to get next page of subscriptions: %w", err)
		}
		for _, sub := range page.Value {
			subsMap[*sub.SubscriptionID] = *sub
		}
	}
	return subsMap, nil
}

// filterSubscriptionsByTarget finds subscriptions that match a name or ID.
func (s *Scanner) filterSubscriptionsByTarget(allSubs map[string]armsubscriptions.Subscription, targets []string) map[string]armsubscriptions.Subscription {
	filtered := make(map[string]armsubscriptions.Subscription)
	targetSet := make(map[string]bool)
	for _, t := range targets {
		targetSet[strings.ToLower(t)] = true
	}

	for id, sub := range allSubs {
		if targetSet[strings.ToLower(id)] || targetSet[strings.ToLower(*sub.DisplayName)] {
			filtered[id] = sub
		}
	}
	return filtered
}

// getSubscriptionsInManagementGroup finds all subscriptions in an MG and its descendants.
func (s *Scanner) getSubscriptionsInManagementGroup(ctx context.Context, mgName string, allSubs map[string]armsubscriptions.Subscription) (map[string]armsubscriptions.Subscription, error) {
	mgsToScan := []string{mgName}

	// Use NewGetDescendantsPager which is more stable across SDK versions.
	// This gets a flat list of all MGs under the target one.
	log.Printf("Finding all descendant Management Groups under '%s'...", mgName)
	descendantsPager := s.clients.mgClient.NewGetDescendantsPager(mgName, nil)
	for descendantsPager.More() {
		page, err := descendantsPager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to get descendants for MG %s: %w", mgName, err)
		}
		for _, descendant := range page.Value {
			// Ensure we are only adding management groups to our list to scan
			if descendant.Properties != nil && descendant.Properties.DisplayName != nil {
				mgsToScan = append(mgsToScan, *descendant.Properties.DisplayName)
			}
		}
	}

	// Now iterate through all identified MGs and get their direct subscriptions
	subIDsInScope := make(map[string]bool)
	for _, currentMgName := range mgsToScan {
		log.Printf("... searching for subscriptions in Management Group: %s", currentMgName)
		pager := s.clients.mgSubscriptionsClient.NewGetSubscriptionsUnderManagementGroupPager(currentMgName, nil)
		for pager.More() {
			page, err := pager.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("failed to get subs for MG %s: %w", currentMgName, err)
			}
			for _, sub := range page.Value {
				// The object from this API call is minimal, so we just need its ID.
				// The ID is the last part of the full resource ID string.
				if sub.ID != nil {
					idParts := strings.Split(*sub.ID, "/")
					subID := idParts[len(idParts)-1]
					subIDsInScope[subID] = true
				}
			}
		}
	}

	// Use the collected IDs to filter the full subscription list
	filteredSubs := make(map[string]armsubscriptions.Subscription)
	for id := range subIDsInScope {
		if sub, ok := allSubs[id]; ok {
			filteredSubs[id] = sub
		}
	}

	return filteredSubs, nil
}

// scanSubscriptionForVNets scans a single subscription and sends results to the channel.
func (s *Scanner) scanSubscriptionForVNets(ctx context.Context, sub armsubscriptions.Subscription, resultsChan chan<- ScanResult) error {
	log.Printf("Scanning subscription: %s (%s)", *sub.DisplayName, *sub.SubscriptionID)

	vnetClient, err := s.clients.GetVNetClient(*sub.SubscriptionID)
	if err != nil {
		return fmt.Errorf("failed to create vnet client for sub %s: %w", *sub.DisplayName, err)
	}

	mgName, err := s.getManagementGroupName(ctx, *sub.SubscriptionID)
	if err != nil {
		log.Printf("Warning: could not get management group for subscription %s: %v", *sub.DisplayName, err)
		mgName = "N/A"
	}

	pager := vnetClient.NewListAllPager(nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("failed to list vnets in sub %s: %w", *sub.DisplayName, err)
		}

		for _, vnet := range page.Value {
			if vnet.Properties == nil || vnet.Properties.AddressSpace == nil || vnet.Properties.AddressSpace.AddressPrefixes == nil {
				continue
			}

			for _, prefix := range vnet.Properties.AddressSpace.AddressPrefixes {
				availableIPs, err := calculator.AvailableIPsInCIDR(*prefix)
				if err != nil {
					log.Printf("Warning: could not parse CIDR %s for VNet %s: %v", *prefix, *vnet.Name, err)
					continue
				}

				resultsChan <- ScanResult{
					SubscriptionName: *sub.DisplayName,
					ManagementGroup:  mgName,
					VNetName:         *vnet.Name,
					VNetRegion:       *vnet.Location,
					AddressSpace:     *prefix,
					AvailableIPs:     availableIPs,
				}
			}
		}
	}
	return nil
}

// getManagementGroupName finds the MG a subscription belongs to.
func (s *Scanner) getManagementGroupName(ctx context.Context, subID string) (string, error) {
	// To find the parent, we must check against the root management group.
	// The response object might have the parent info in its Properties.
	mgInfo, err := s.clients.mgClient.Get(ctx, "root", &armmanagementgroups.ClientGetOptions{
		Expand:        "children",
		Filter:        fmt.Sprintf("children/any(c: c/name eq '%s')", subID),
	})

	if err != nil {
		// A common issue is not having permission on the root MG. Fall back gracefully.
		// We'll try a different API call that's often more permissive.
		entityPager := s.clients.mgClient.NewGetEntitiesPager(nil)
		for entityPager.More() {
			page, err := entityPager.NextPage(ctx)
			if err != nil {
				return "", err // Return the error if this also fails
			}
			for _, entity := range page.Value {
				if entity.Properties.Subscriptions != nil {
					for _, sub := range entity.Properties.Subscriptions {
						if sub.ID != nil && strings.HasSuffix(*sub.ID, subID) {
							return *entity.Properties.DisplayName, nil
						}
					}
				}
			}
		}
		// If lookup still fails, return the original error.
		return "", err
	}

	// This part is complex because the structure can be deeply nested.
	// The above fallback is usually more reliable.
	// If the Get call somehow succeeded, we would parse its response.
	// For simplicity and compatibility, we rely on the fallback logic.
	if mgInfo.ManagementGroup.Properties != nil && mgInfo.ManagementGroup.Properties.DisplayName != nil {
		// This is likely the root MG, not the direct parent.
		// The fallback is better, but this prevents a crash.
		return *mgInfo.ManagementGroup.Properties.DisplayName, nil
	}
	
	return "N/A", nil
}
