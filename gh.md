# Features of this Script:
- Two Modes: Scan all repositories in an organization or a specific list of repositories.
- Beautiful Console Output: Uses colors, emojis, and formatted tables with printf.
- HTML Report Generation: Creates a self-contained HTML file with embedded CSS, perfect for sending in an email.
- Efficient: It minimizes API calls by fetching all branches once per repository instead of checking each branch individually.
- Prerequisite Checks: Ensures gh and jq are installed and that you are logged in.
- Easy Configuration: All user-specific settings are at the top of the script.

# Prerequisites
- Install gh CLI: Follow the official installation guide: https://github.com/cli/cli#installation
- Install jq: A lightweight command-line JSON processor.

```bash
#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status.

#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#
#                                                              #
#             GitHub Pull Request Health Report                #
#                                                              #
#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#_#

# =================================================================================
#  CONFIGURATIONS - PLEASE EDIT THESE VALUES
# =================================================================================

# gh auth status --hostname github.my-company-internal.com
# gh auth login --hostname github.my-company-internal.com

## NEW ##
# 0. Set your GitHub Enterprise hostname (e.g., github.your-company.com)
#    DO NOT include "https://" or a trailing slash.
GHE_HOSTNAME="github.your-company.com"

# 1. Set your GitHub Enterprise organization name.
ORG_NAME="your-github-organization"

# 2. Choose the scan mode:
#    - "org":  Scan all repositories in the organization specified above.
#    - "list": Scan only the repositories listed in the REPOS_ARRAY below.
SCAN_MODE="org" # or "list"

# 3. If using SCAN_MODE="list", define your repositories here.
#    The script will automatically prefix them with "${ORG_NAME}/".
REPOS_ARRAY=(
  "my-awesome-app"
  "our-cool-service"
  "the-best-library"
)

# 4. Set the output file for the HTML report.
HTML_OUTPUT_FILE="github_report_$(date +%Y-%m-%d).html"

# =================================================================================
#  SCRIPT CORE - No need to edit below this line
# =================================================================================

# --- Colors and Emojis for Console Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

EMOJI_REVIEW="🔍"
EMOJI_BRANCH="🌿"
EMOJI_SUCCESS="✅"
EMOJI_ERROR="❌"
EMOJI_INFO="ℹ️"

# --- Global Counters ---
TOTAL_PRS_AWAITING_REVIEW=0
TOTAL_UNDELETED_BRANCHES=0

# --- Function to check for required commands ---
check_dependencies() {
  echo -e "${BLUE}Checking for required tools...${NC}"
  if ! command -v gh &> /dev/null; then
    echo -e "${RED}${EMOJI_ERROR} 'gh' CLI is not installed. Please install it to continue.${NC}"
    echo "Installation guide: https://github.com/cli/cli#installation"
    exit 1
  fi
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}${EMOJI_ERROR} 'jq' is not installed. Please install it to continue.${NC}"
    echo "On Debian/Ubuntu: sudo apt-get install jq"
    echo "On macOS (Homebrew): brew install jq"
    exit 1
  fi
  # Check if logged in to the specified host
  ## MODIFIED ##
  if ! gh auth status --hostname "$GHE_HOSTNAME" &> /dev/null; then
      echo -e "${RED}${EMOJI_ERROR} You are not logged into '$GHE_HOSTNAME'.${NC}"
      echo -e "${YELLOW}Please run: gh auth login --hostname ${GHE_HOSTNAME}${NC}"
      exit 1
  fi
  echo -e "${GREEN}${EMOJI_SUCCESS} All dependencies are met and logged into ${GHE_HOSTNAME}.${NC}\n"
}

# --- Functions for HTML Generation ---
# ... (HTML functions are unchanged, so they are omitted here for brevity) ...
# ... (You can just keep the functions from the previous version) ...
# --- Core Logic Functions ---
# ... (The core logic functions are also unchanged) ...

# --- Main Execution ---
main() {
    ## NEW ##
    # Set the GH_HOST environment variable to ensure all gh commands target the correct host
    export GH_HOST="$GHE_HOSTNAME"

    check_dependencies
    
    # Get the list of repos based on the chosen mode
    repo_list=$(get_repo_list)
    if [[ -z "$repo_list" ]]; then
      echo -e "${RED}${EMOJI_ERROR} No repositories found. Please check your ORG_NAME or REPOS_ARRAY configuration.${NC}"
      exit 1
    fi

    # Initialize HTML file
    init_html "$HTML_OUTPUT_FILE"

    # --- Section 1: PRs Awaiting Review ---
    add_html_section_header "${EMOJI_REVIEW}" "Pull Requests Awaiting Review" "$HTML_OUTPUT_FILE"
    declare -A headers_review=(
        ["Repo"]="Repo" ["#PR"]="#PR" ["Title"]="Title" ["Author"]="Author" 
        ["Created"]="Created" ["Reviewers"]="Reviewers" ["Link"]="Link"
    )
    start_html_table headers_review[@] "$HTML_OUTPUT_FILE"

    echo -e "\n${BLUE}Scanning repositories for PRs awaiting review...${NC}"
    while IFS= read -r repo; do
        echo -n "." # Progress indicator
        process_review_prs "${ORG_NAME}/${repo}"
    done <<< "$repo_list"
    echo # Newline after progress dots
    
    if [[ $TOTAL_PRS_AWAITING_REVIEW -eq 0 ]]; then
        echo -e "${GREEN}No open PRs awaiting review found.${NC}"
        add_html_empty_state "No open PRs awaiting review found. Great job!" "$HTML_OUTPUT_FILE"
    fi
    end_html_table "$HTML_OUTPUT_FILE"
    add_html_summary "Total PRs Awaiting Review" "$TOTAL_PRS_AWAITING_REVIEW" "$HTML_OUTPUT_FILE"


    # --- Section 2: PRs with Undeleted Branches ---
    add_html_section_header "${EMOJI_BRANCH}" "PRs with Undeleted Branches" "$HTML_OUTPUT_FILE"
    declare -A headers_branches=(
        ["Repo"]="Repo" ["#PR"]="#PR" ["Branch Name"]="Branch Name" ["Title"]="Title" 
        ["Merged By"]="Merged By" ["Merged At"]="Merged At" ["Link"]="Link"
    )
    start_html_table headers_branches[@] "$HTML_OUTPUT_FILE"

    echo -e "\n${BLUE}Scanning repositories for undeleted branches from merged PRs...${NC}"
    while IFS= read -r repo; do
        echo -n "." # Progress indicator
        process_undeleted_branches "${ORG_NAME}/${repo}"
    done <<< "$repo_list"
    echo # Newline after progress dots

    if [[ $TOTAL_UNDELETED_BRANCHES -eq 0 ]]; then
        echo -e "${GREEN}No PRs with undeleted branches found.${NC}"
        add_html_empty_state "No merged PRs with undeleted branches were found. Excellent branch hygiene!" "$HTML_OUTPUT_FILE"
    fi
    end_html_table "$HTML_OUTPUT_FILE"
    add_html_summary "Total PRs with Undeleted Branches" "$TOTAL_UNDELETED_BRANCHES" "$HTML_OUTPUT_FILE"

    # Finalize HTML and print summary
    finalize_html "$HTML_OUTPUT_FILE"

    echo -e "\n${GREEN}--- Report Summary ---${NC}"
    echo -e "${EMOJI_REVIEW} Total PRs Awaiting Review: ${YELLOW}${TOTAL_PRS_AWAITING_REVIEW}${NC}"
    echo -e "${EMOJI_BRANCH} Total PRs with Undeleted Branches: ${YELLOW}${TOTAL_UNDELETED_BRANCHES}${NC}"
    echo -e "\n${EMOJI_SUCCESS} ${GREEN}HTML report has been generated successfully!${NC}"
    echo -e "${CYAN}File location: $(pwd)/${HTML_OUTPUT_FILE}${NC}"
}

# Run the main function
main
```

# How to Use the Script
1. Save the Code: Save the script above as a file, for example, github_pr_report.sh.
2. Make it Executable: Open your terminal and run chmod +x github_pr_report.sh.
3. Configure: Open the file in a text editor and modify the variables in the CONFIGURATIONS section:
- ORG_NAME: Your GitHub Enterprise organization name.
- SCAN_MODE: Set to "org" to scan everything or "list" to use the array.
- REPOS_ARRAY: If using "list" mode, populate this with the names of your repositories.
- HTML_OUTPUT_FILE: Change the name of the report file if you wish.
4. Run the Script : ./github_pr_report.sh

```text
Checking for required tools...
✅ All dependencies are met.

Fetching all repositories for organization: your-github-organization...

Scanning repositories for PRs awaiting review...
..
--- 🔍 Pull Requests Awaiting Review ---
REPO            #PR        TITLE                                              AUTHOR               CREATED         REVIEWERS                
----            ---        -----                                              ------               -------         ---------                
my-awesome-app  #101       Feat: Add amazing new login page                   jane-doe             2023-10-27      dev-team,john-smith      
our-cool-service #42        Fix: Correct the data processing pipeline          another-dev          2023-10-26      jane-doe                 
..

Scanning repositories for undeleted branches from merged PRs...
.
--- 🌿 PRs with Undeleted Branches ---
REPO            #PR        BRANCH NAME                              TITLE                     MERGED BY            MERGED AT           
----            ---        -----------                              -----                     ---------            ---------           
my-awesome-app  #95        feature/old-login-logic                  Old Login Logic           jane-doe             2023-10-15          
the-best-library #12        fix/bug-in-calculation                   Fix calculation bug       another-dev          2023-09-01          
.

--- Report Summary ---
🔍 Total PRs Awaiting Review: 2
🌿 Total PRs with Undeleted Branches: 2

✅ HTML report has been generated successfully!
ℹ️ File location: /home/user/github_report_2023-10-27.html
```

# The Generated HTML File

When you open the .html file generated by the script, you will see a clean, professional-looking report with tables and links, ready to be viewed in a browser or sent via email.





