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

GHE_HOSTNAME="github.your-company.com"
ORG_NAME="your-github-organization"
SCAN_MODE="org"
REPOS_ARRAY=( "my-awesome-app" "our-cool-service" "the-best-library" )
DAYS_THRESHOLD=7
HTML_OUTPUT_FILE="github_report_$(date +%Y-%m-%d).html"

# =================================================================================
#  EMAIL CONFIGURATIONS (Python based)
# =================================================================================
SEND_EMAIL="true"
SMTP_SERVER="smtp.your-company.com:25"
EMAIL_FROM_NAME="GitHub Reporter"
EMAIL_FROM_ADDR="no-reply@your-company.com"
EMAIL_TO="dev-team@your-company.com,another-dev@company.com"
EMAIL_CC="engineering-manager@your-company.com"

# =================================================================================
#  SCRIPT CORE - No need to edit below this line
# =================================================================================

# --- Colors, Emojis, and Table Formatting ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
EMOJI_REVIEW="🔍"; EMOJI_BRANCH="🌿"; EMOJI_SUCCESS="✅"; EMOJI_ERROR="❌"; EMOJI_INFO="ℹ️"
T_BORDER="┌"; M_BORDER="├"; L_BORDER="└"; H_BORDER="─"; V_BORDER="│"
PYTHON_MAILER_SCRIPT="send_email_gh_report.py"

# --- Global Counters ---
TOTAL_PRS_AWAITING_REVIEW=0
TOTAL_UNDELETED_BRANCHES=0

# --- Function to check for required commands ---
check_dependencies() {
  echo -e "${BLUE}Checking for required tools...${NC}"
  if ! command -v gh &> /dev/null; then echo -e "${RED}${EMOJI_ERROR} 'gh' CLI is not installed.${NC}"; exit 1; fi
  if ! command -v jq &> /dev/null; then echo -e "${RED}${EMOJI_ERROR} 'jq' is not installed.${NC}"; exit 1; fi
  if ! gh auth status --hostname "$GHE_HOSTNAME" &> /dev/null; then
      echo -e "${RED}${EMOJI_ERROR} You are not logged into '$GHE_HOSTNAME'.\nPlease run: gh auth login --hostname ${GHE_HOSTNAME}${NC}"
      exit 1
  fi
  echo -e "${GREEN}${EMOJI_SUCCESS} All dependencies are met and logged into ${GHE_HOSTNAME}.${NC}\n"
}

# --- Functions for HTML Generation (Unchanged) ---
init_html() {
cat <<EOF > "$1"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>GitHub Pull Request Report for ${ORG_NAME}</title><style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans",Helvetica,Arial,sans-serif;line-height:1.6;color:#333;margin:0;padding:20px;background-color:#f9f9f9}.container{max-width:1200px;margin:auto;background:#fff;padding:25px;border-radius:8px;box-shadow:0 2px 10px rgba(0,0,0,0.1)}h1,h2{border-bottom:2px solid #eee;padding-bottom:10px;margin-top:30px;color:#1a1a1a}h1{font-size:2em}h2{font-size:1.5em}table{border-collapse:collapse;width:100%;margin-top:20px}th,td{border:1px solid #ddd;padding:12px;text-align:left}th{background-color:#f2f2f2;font-weight:bold}tr:nth-child(even){background-color:#f9f9f9}tr:hover{background-color:#f1f1f1}a{color:#0366d6;text-decoration:none}a:hover{text-decoration:underline}.footer{text-align:center;margin-top:30px;font-size:0.9em;color:#777}.empty-state{padding:20px;text-align:center;color:#888;background-color:#fafafa;border:1px dashed #ddd}.total-count{font-weight:bold;font-size:1.2em}</style></head><body><div class="container"><h1>${EMOJI_REVIEW} GitHub PR Report for ${ORG_NAME}</h1><p>Generated on: $(date)</p>
EOF
}
start_html_table() { local outfile=$1; shift; local headers=("$@"); echo "<table><thead><tr>" >> "$outfile"; for header in "${headers[@]}"; do echo "<th>${header}</th>" >> "$outfile"; done; echo "</tr></thead><tbody>" >> "$outfile"; }
add_html_row() { local outfile=$1; shift; local cells=("$@"); echo "<tr>" >> "$outfile"; for cell in "${cells[@]}"; do if [[ "$cell" == http* ]]; then echo "<td><a href=\"$cell\" target=\"_blank\">Link</a></td>" >> "$outfile"; else echo "<td>${cell}</td>" >> "$outfile"; fi; done; echo "</tr>" >> "$outfile"; }
add_html_section_header() { echo "<h2>$1 $2</h2>" >> "$3"; }
end_html_table() { echo "</tbody></table>" >> "$1"; }
add_html_empty_state() { echo "<div class='empty-state'>$1</div>" >> "$2"; }
add_html_summary() { echo "<p class='total-count'>$1: $2</p>" >> "$3"; }
finalize_html() { cat <<EOF >> "$1"; <div class="footer"><p>Report generated by the GitHub PR Health Script.</p></div></div></body></html>EOF; }

# --- Function to create the Python email script ---
create_python_mailer() {
cat <<EOF > "$PYTHON_MAILER_SCRIPT"
#!/usr/bin/env python3
import sys
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr, COMMASPACE

# --- Arguments from Bash script ---
SMTP_SERVER = sys.argv[1]
SENDER_NAME = sys.argv[2]
SENDER_ADDR = sys.argv[3]
RECIPIENTS_TO = [addr.strip() for addr in sys.argv[4].split(',') if addr.strip()]
RECIPIENTS_CC = [addr.strip() for addr in sys.argv[5].split(',') if addr.strip()]
SUBJECT = sys.argv[6]

HTML_BODY = sys.stdin.read()

## MODIFIED: All debug output now goes to stderr to avoid interfering with other processes. ##
def log_debug(message):
    print(message, file=sys.stderr)

log_debug("--- Python Mailer Debug ---")
log_debug(f"SMTP Server: {SMTP_SERVER}")
log_debug(f"From: {SENDER_NAME} <{SENDER_ADDR}>")
log_debug(f"To: {RECIPIENTS_TO}")
log_debug(f"Cc: {RECIPIENTS_CC}")
log_debug(f"Subject: {SUBJECT}")
log_debug("---------------------------")

# --- Create the email message ---
msg = MIMEMultipart('alternative')
msg['Subject'] = SUBJECT
msg['From'] = formataddr((SENDER_NAME, SENDER_ADDR))
msg['To'] = COMMASPACE.join(RECIPIENTS_TO)
if RECIPIENTS_CC:
    msg['Cc'] = COMMASPACE.join(RECIPIENTS_CC)

msg.attach(MIMEText(HTML_BODY, 'html', 'utf-8'))
all_recipients = RECIPIENTS_TO + RECIPIENTS_CC

# --- Send the email ---
try:
    log_debug("Connecting to SMTP server...")
    with smtplib.SMTP(SMTP_SERVER) as server:
        server.send_message(msg)
    log_debug("Python: Email sent successfully!")
except Exception as e:
    log_debug(f"Python: Failed to send email. Error: {e}")
    sys.exit(1)
EOF
    chmod +x "$PYTHON_MAILER_SCRIPT"
}

# --- Function to send email using the Python script ---
send_email_report() {
    if [[ "$SEND_EMAIL" != "true" ]]; then
        echo -e "\n${YELLOW}Email sending is disabled. Skipping.${NC}"; return
    fi
    if ! command -v python3 &> /dev/null; then
        echo -e "\n${RED}${EMOJI_ERROR} 'python3' command not found. Cannot send email.${NC}"; return
    fi
    local html_file="$1"
    local subject="GitHub PR Health Report - $(date +'%Y-%m-%d')"
    echo -e "\n${BLUE}Sending email report to '$EMAIL_TO' using Python...${NC}"

    ## MODIFIED: Added the -u flag to force unbuffered output from Python ##
    python3 -u "$PYTHON_MAILER_SCRIPT" \
        "$SMTP_SERVER" \
        "$EMAIL_FROM_NAME" \
        "$EMAIL_FROM_ADDR" \
        "$EMAIL_TO" \
        "$EMAIL_CC" \
        "$subject" < "$html_file"

    echo -e "${GREEN}${EMOJI_SUCCESS} Email sending process completed.${NC}"
}

# --- Core Logic Functions (Unchanged) ---
get_days_open_html() { local created_at_iso="$1"; local pr_timestamp=$(date -d "$created_at_iso" +%s); local now_timestamp=$(date +%s); local seconds_diff=$((now_timestamp - pr_timestamp)); local days_open=$((seconds_diff / 86400)); local emoji="🔵"; if [ "$days_open" -gt "$DAYS_THRESHOLD" ]; then emoji="🔴"; fi; echo "$days_open days $emoji"; }
get_repo_list() { if [[ "$SCAN_MODE" == "org" ]]; then echo -e "${BLUE}Fetching all repositories for organization: ${ORG_NAME}...${NC}"; gh repo list "$ORG_NAME" --limit 1000 --json name --jq '.[].name'; else echo -e "${BLUE}Using predefined list of repositories...${NC}"; printf '%s\n' "${REPOS_ARRAY[@]}"; fi; }
process_review_prs() { local repo_full_name="$1"; local pr_list_json; pr_list_json=$(gh pr list -R "$repo_full_name" --state open --limit 100 --json number,title,url,author,createdAt,reviewRequests --search "-is:draft" 2>/dev/null); local prs; prs=$(echo "$pr_list_json" | jq -r '.[] | [.number, .title, .url, .author.login, .createdAt, ([.reviewRequests[]? | .login // .name] | join(" ")) // "None"] | @tsv'); if [[ -z "$prs" ]]; then return 0; fi; local count=0; local repo_header_printed=false; while IFS=$'\t' read -r number title url author created_at_iso reviewers; do if ! $repo_header_printed; then repo_short_name=$(basename "$repo_full_name"); echo -e "${CYAN}${T_BORDER}${H_BORDER}${H_BORDER} [${repo_short_name}] ${H_BORDER}"; printf "${CYAN}${V_BORDER}${NC} %-9s %-45s %-20s %-25s\n" "PR #" "Title" "Author" "Reviewers"; echo -e "${CYAN}${M_BORDER}─────────────────────────────────────────────────────────────────────────────────────────────────"; repo_header_printed=true; fi; printf "${CYAN}${V_BORDER}${NC} ${YELLOW}#%-8s${NC} %-45.45s %-20s ${RED}%-25.25s${NC}\n" "$number" "$title" "$author" "$reviewers"; local days_open_html=$(get_days_open_html "$created_at_iso"); local -a row=("$days_open_html" "#${number}" "$title" "$author" "$reviewers" "$url"); add_html_row "$HTML_OUTPUT_FILE" "${row[@]}"; count=$((count + 1)); done <<< "$prs"; if $repo_header_printed; then echo -e "${CYAN}${L_BORDER}${H_BORDER}${H_BORDER}${NC}"; fi; TOTAL_PRS_AWAITING_REVIEW=$((TOTAL_PRS_AWAITING_REVIEW + count)); }
process_undeleted_branches() { local repo_full_name="$1"; local branches; branches=$(gh api "repos/$repo_full_name/branches" --paginate -q '.[].name' 2>/dev/null); if [[ -z "$branches" ]]; then return 0; fi; local merged_prs_json; merged_prs_json=$(gh pr list -R "$repo_full_name" --state merged --limit 100 --json headRefName,number,title,url,mergedBy,mergedAt,isCrossRepository 2>/dev/null); local prs_to_check; prs_to_check=$(echo "$merged_prs_json" | jq -r '.[] | select(.isCrossRepository == false) | [.headRefName, .number, .title, .url, .mergedBy.login, (.mergedAt|fromdate|strflocaltime("%Y-%m-%d"))] | @tsv'); if [[ -z "$prs_to_check" ]]; then return 0; fi; local count=0; local repo_header_printed=false; while IFS=$'\t' read -r branch_name pr_number title url merged_by merged_at; do if grep -q -x "$branch_name" <<< "$branches"; then if ! $repo_header_printed; then repo_short_name=$(basename "$repo_full_name"); echo -e "${CYAN}${T_BORDER}${H_BORDER}${H_BORDER} [${repo_short_name}] ${H_BORDER}"; printf "${CYAN}${V_BORDER}${NC} %-9s %-40s %-20s %-15s\n" "PR #" "Branch Name" "Merged By" "Merged At"; echo -e "${CYAN}${M_BORDER}──────────────────────────────────────────────────────────────────────────────────────────────────"; repo_header_printed=true; fi; printf "${CYAN}${V_BORDER}${NC} ${YELLOW}#%-8s${NC} ${RED}%-40.40s${NC} %-20s %-15s\n" "$pr_number" "$branch_name" "$merged_by" "$merged_at"; local -a row=("$repo_short_name" "#${pr_number}" "$branch_name" "$title" "$merged_by" "$merged_at" "$url"); add_html_row "$HTML_OUTPUT_FILE" "${row[@]}"; count=$((count + 1)); fi; done <<< "$prs_to_check"; if $repo_header_printed; then echo -e "${CYAN}${L_BORDER}${H_BORDER}${H_BORDER}${NC}"; fi; TOTAL_UNDELETED_BRANCHES=$((TOTAL_UNDELETED_BRANCHES + count)); }

# --- Main Execution ---
main() {
    export GH_HOST="$GHE_HOSTNAME"; check_dependencies; create_python_mailer
    repo_list=$(get_repo_list); if [[ -z "$repo_list" ]]; then echo -e "${RED}${EMOJI_ERROR} No repositories found.${NC}"; exit 1; fi
    init_html "$HTML_OUTPUT_FILE"
    echo -e "\n${BLUE}Scanning for Pull Requests Awaiting Review...${NC}"; add_html_section_header "${EMOJI_REVIEW}" "Pull Requests Awaiting Review" "$HTML_OUTPUT_FILE"; declare -a headers_review=("Days Open" "#PR" "Title" "Author" "Reviewers" "Link"); start_html_table "$HTML_OUTPUT_FILE" "${headers_review[@]}"; while IFS= read -r repo; do process_review_prs "${ORG_NAME}/${repo}"; done <<< "$repo_list"
    if [[ $TOTAL_PRS_AWAITING_REVIEW -eq 0 ]]; then echo -e "${GREEN}No open PRs awaiting review found.${NC}"; add_html_empty_state "Great job!" "$HTML_OUTPUT_FILE"; fi; end_html_table "$HTML_OUTPUT_FILE"; add_html_summary "Total PRs Awaiting Review" "$TOTAL_PRS_AWAITING_REVIEW" "$HTML_OUTPUT_FILE"
    echo -e "\n${BLUE}Scanning for PRs with Undeleted Branches...${NC}"; add_html_section_header "${EMOJI_BRANCH}" "PRs with Undeleted Branches" "$HTML_OUTPUT_FILE"; declare -a headers_branches=("Repo" "#PR" "Branch Name" "Title" "Merged By" "Merged At" "Link"); start_html_table "$HTML_OUTPUT_FILE" "${headers_branches[@]}"; while IFS= read -r repo; do process_undeleted_branches "${ORG_NAME}/${repo}"; done <<< "$repo_list"
    if [[ $TOTAL_UNDELETED_BRANCHES -eq 0 ]]; then echo -e "${GREEN}No PRs with undeleted branches found.${NC}"; add_html_empty_state "Excellent branch hygiene!" "$HTML_OUTPUT_FILE"; fi; end_html_table "$HTML_OUTPUT_FILE"; add_html_summary "Total PRs with Undeleted Branches" "$TOTAL_UNDELETED_BRANCHES" "$HTML_OUTPUT_FILE"
    finalize_html "$HTML_OUTPUT_FILE"
    echo -e "\n${GREEN}--- Report Summary ---${NC}"; echo -e "${EMOJI_REVIEW} Total PRs Awaiting Review: ${YELLOW}${TOTAL_PRS_AWAITING_REVIEW}${NC}"; echo -e "${EMOJI_BRANCH} Total PRs with Undeleted Branches: ${YELLOW}${TOTAL_UNDELETED_BRANCHES}${NC}"
    echo -e "\n${EMOJI_SUCCESS} ${GREEN}HTML report generated: ${CYAN}$(pwd)/${HTML_OUTPUT_FILE}${NC}"
    send_email_report "$HTML_OUTPUT_FILE"
}

main
