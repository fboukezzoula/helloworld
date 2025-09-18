Step 1: Correct internal/azure/clients.go
The error undefined: armmanagementgroups.SubscriptionsClient tells us this type doesn't exist. The correct type is armmanagementgroups.ManagementGroupSubscriptionsClient.

Replace the entire content of azure-vnet-scanner/internal/azure/clients.go with this corrected version:

```go
// azure-vnet-scanner/internal/azure/clients.go
package azure

import (
	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/managementgroups/armmanagementgroups"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/network/armnetwork"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resources/armsubscriptions"
)

// Clients holds all the necessary Azure SDK clients.
type Clients struct {
	cred                  azcore.TokenCredential
	subsClient            *armsubscriptions.Client
	mgClient              *armmanagementgroups.Client
	mgSubscriptionsClient *armmanagementgroups.ManagementGroupSubscriptionsClient // <-- CORRECTED TYPE
}

// NewClients creates a new set of Azure clients.
func NewClients(cred azcore.TokenCredential) (*Clients, error) {
	subsClient, err := armsubscriptions.NewClient(cred, nil)
	if err != nil {
		return nil, err
	}
	mgClient, err := armmanagementgroups.NewClient(cred, nil)
	if err != nil {
		return nil, err
	}
	// This is the corrected constructor for the client.
	mgSubscriptionsClient, err := armmanagementgroups.NewManagementGroupSubscriptionsClient(cred, nil) // <-- CORRECTED CONSTRUCTOR
	if err != nil {
		return nil, err
	}

	return &Clients{
		cred:                  cred,
		subsClient:            subsClient,
		mgClient:              mgClient,
		mgSubscriptionsClient: mgSubscriptionsClient,
	}, nil
}

// GetVNetClient is a factory method to create a VNet client for a specific subscription.
func (c *Clients) GetVNetClient(subscriptionID string) (*armnetwork.VirtualNetworksClient, error) {
	return armnetwork.NewVirtualNetworksClient(subscriptionID, c.cred, nil)
}
```

Changes Made:

armmanagementgroups.SubscriptionsClient was changed to armmanagementgroups.ManagementGroupSubscriptionsClient.
armmanagementgroups.NewSubscriptionsClient was changed to armmanagementgroups.NewManagementGroupSubscriptionsClient.


Step 2: Correct internal/azure/scanner.go
The error s.clients.mgClient.NewGetChildrenPager undefined tells us this method doesn't exist. The correct method for listing children is NewListChildrenPager.

Replace the entire content of azure-vnet-scanner/internal/azure/scanner.go with this corrected version:

```go
// azure-vnet-scanner/internal/azure/scanner.go
package azure

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"

	"github.com/your-username/azure-vnet-scanner/internal/calculator"
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
	var g, gCtx = errgroup.WithContext(ctx)

	// Concurrently scan each subscription
	for _, sub := range subsToScan {
		// Capture the loop variable
		currentSub := sub
		wg.Add(1)
		g.Go(func() error {
			defer wg.Done()
			return s.scanSubscriptionForVNets(gCtx, currentSub, resultsChan)
		})
	}

	// A goroutine to close the results channel once all workers are done
	go func() {
		wg.Wait()
		close(resultsChan)
	}()

	// Collect results
	var allResults []ScanResult
	for result := range resultsChan {
		allResults = append(allResults, result)
	}

	// Check for errors from the errgroup
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

	// Case 1: Target specific subscriptions
	if len(opts.TargetSubscriptions) > 0 {
		return s.filterSubscriptionsByTarget(allSubs, opts.TargetSubscriptions), nil
	}

	// Case 2: Target a management group
	if opts.TargetManagementGroup != "" {
		return s.getSubscriptionsInManagementGroup(ctx, opts.TargetManagementGroup)
	}

	// Case 3: Default to all subscriptions in the tenant
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

// getSubscriptionsInManagementGroup recursively finds all subscriptions in an MG and its children.
func (s *Scanner) getSubscriptionsInManagementGroup(ctx context.Context, mgName string) (map[string]armsubscriptions.Subscription, error) {
	subsInMg := make(map[string]armsubscriptions.Subscription)
	
	// Use a queue for breadth-first search of the MG hierarchy
	mgQueue := []string{mgName}
	processedMGs := make(map[string]bool)

	for len(mgQueue) > 0 {
		currentMgName := mgQueue[0]
		mgQueue = mgQueue[1:]

		if processedMGs[currentMgName] {
			continue
		}
		processedMGs[currentMgName] = true
		
		log.Printf("... searching for subscriptions in Management Group: %s", currentMgName)

		// Get subscriptions in the current MG
		pager := s.clients.mgSubscriptionsClient.NewGetSubscriptionsUnderManagementGroupPager(currentMgName, nil)
		for pager.More() {
			page, err := pager.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("failed to get subs for MG %s: %w", currentMgName, err)
			}
			for _, sub := range page.Value {
				if sub.ID != nil && sub.DisplayName != nil {
					// The API gives us a different object, so we need to construct a standard subscription object
					subIDParts := strings.Split(*sub.ID, "/")
					subID := subIDParts[len(subIDParts)-1]
					subsInMg[subID] = armsubscriptions.Subscription{
						ID:             &subID,
						SubscriptionID: &subID,
						DisplayName:    sub.DisplayName,
					}
				}
			}
		}

		// Get child MGs and add them to the queue
		// This is the corrected method name for the pager.
		childrenPager := s.clients.mgClient.NewListChildrenPager(currentMgName, nil) // <-- CORRECTED METHOD
		for childrenPager.More() {
			page, err := childrenPager.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("failed to get children for MG %s: %w", currentMgName, err)
			}
			for _, child := range page.Value {
				if child.Type != nil && *child.Type == "/providers/Microsoft.Management/managementGroups" {
					mgQueue = append(mgQueue, *child.Name)
				}
			}
		}
	}
	
	return subsInMg, nil
}

// scanSubscriptionForVNets scans a single subscription and sends results to the channel.
func (s *Scanner) scanSubscriptionForVNets(ctx context.Context, sub armsubscriptions.Subscription, resultsChan chan<- ScanResult) error {
	log.Printf("Scanning subscription: %s (%s)", *sub.DisplayName, *sub.SubscriptionID)

	vnetClient, err := s.clients.GetVNetClient(*sub.SubscriptionID)
	if err != nil {
		return fmt.Errorf("failed to create vnet client for sub %s: %w", *sub.DisplayName, err)
	}

	// This is an extra API call to find the MG. Could be cached for performance.
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
	// Note: This API requires tenant-level permissions to read management groups.
	// `Reader` at the tenant root is sufficient.
	// We need to get the MG info from the correct client now.
	mgInfo, err := s.clients.mgSubscriptionsClient.GetSubscription(ctx, "root", subID, nil)
	if err != nil {
		return "", err
	}
	if mgInfo.SubscriptionUnderManagementGroup.Parent != nil && mgInfo.SubscriptionUnderManagementGroup.Parent.DisplayName != nil {
		return *mgInfo.SubscriptionUnderManagementGroup.Parent.DisplayName, nil
	}
	return "N/A", nil
}
```
Changes Made:

s.clients.mgClient.NewGetChildrenPager was changed to s.clients.mgClient.NewListChildrenPager.
I also noticed a potential nil pointer dereference if child.Type was nil, so I added a check for that (if child.Type != nil && ...).
The import for armmanagementgroups was no longer needed in this specific file, so I removed it to prevent the "imported and not used" error.
Step 3: Tidy Dependencies and Re-build
After saving the changes to both files, run the following commands in your terminal from the project's root directory:

Tidy up the go.mod file. This will remove unused dependencies and fetch any new ones if necessary.


go mod tidy
go build -o azure-vnet-scanner .


