## Prerequisites

- Personal Access Token (PAT):
  - Create a PAT with a user account (or service account) that has Write access to the repositories in orgaB.
  - Scopes: Select repo (full control of private repositories).
  - Secret: Save this token in the orgaA/sourceA repository secrets as PAT_TOKEN.


```yaml
name: Deploy Readme via PR

on:
  workflow_dispatch:
    inputs:
      target_repo_name:
        description: 'Target repo name (or "all")'
        required: true
        default: 'all'
        type: string

env:
  # Configuration
  TARGET_ORG: "orgaB"
  # Git user configuration for commits
  GIT_USER_NAME: "GitHub Action Bot"
  GIT_USER_EMAIL: "bot@your-company.com"
  # Your GitHub Enterprise Server URL (Crucial for gh cli)
  GH_HOST: "github.your-company.com" 

jobs:
  distribute-readme:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Repo (sourceA)
        uses: actions/checkout@v3
        with:
          path: source_repo

      - name: Authenticate GitHub CLI
        run: |
          # Authentication using the PAT
          echo "${{ secrets.PAT_TOKEN }}" | gh auth login --with-token --hostname ${{ env.GH_HOST }}
          
          # Global Git config for the bot
          git config --global user.name "${{ env.GIT_USER_NAME }}"
          git config --global user.email "${{ env.GIT_USER_EMAIL }}"

      - name: Process Deployment
        shell: bash
        env:
          GH_TOKEN: ${{ secrets.PAT_TOKEN }}
          INPUT_REPO: ${{ inputs.target_repo_name }}
        run: |
          # 1. Define the deployment list
          # Array format: "TARGET_REPO_NAME|SOURCE_FILE_NAME"
          declare -a DEPLOYMENTS
          
          # Absolute path to source files
          SOURCE_DIR="$GITHUB_WORKSPACE/source_repo"

          if [ "$INPUT_REPO" == "all" ]; then
            echo "Mode: Global deployment (ALL)"
            
            # --- MANUALLY MAINTAINED LIST FOR 'ALL' ---
            # Logic: sourceA/readme.md -> target/readme.md
            DEPLOYMENTS+=("REPO_A|readme.md")
            DEPLOYMENTS+=("REPO_B|readme.md")
            DEPLOYMENTS+=("REPO_C|readme.md")
            # Add other repositories here...
            
          else
            echo "Mode: Targeted deployment for $INPUT_REPO"
            
            # Logic: sourceA/readmeREPO_NAME.md -> target/readme.md
            SPECIFIC_SOURCE="readme${INPUT_REPO}.md"
            
            # Verify source file existence
            if [ ! -f "$SOURCE_DIR/$SPECIFIC_SOURCE" ]; then
              echo "::error::Source file $SPECIFIC_SOURCE does not exist in sourceA."
              exit 1
            fi
            
            DEPLOYMENTS+=("$INPUT_REPO|$SPECIFIC_SOURCE")
          fi

          # 2. Processing function (Clone, Branch, Commit, PR)
          process_repo() {
            local target_repo=$1
            local source_file_name=$2
            local target_full_path="$TARGET_ORG/$target_repo"
            # Unique branch name using timestamp to avoid collisions
            local branch_name="update-readme-$(date +%s)" 

            echo "---------------------------------------------------"
            echo "Processing: $target_full_path using source: $source_file_name"

            # Clean and create temp workspace
            rm -rf temp_work_dir
            mkdir temp_work_dir
            cd temp_work_dir

            # Clone target repo
            echo "Cloning $target_full_path..."
            gh repo clone "$target_full_path" . || { echo "Failed to clone $target_full_path"; return; }

            # Create new branch
            git checkout -b "$branch_name"

            # Copy file (overwrite target readme.md)
            cp "$SOURCE_DIR/$source_file_name" ./readme.md

            # Check for changes
            if git diff --quiet; then
              echo "No changes detected for $target_repo. Skipping."
            else
              echo "Changes detected. Committing and creating PR..."
              
              git add readme.md
              git commit -m "docs: update README from sourceA"
              git push origin "$branch_name"

              # Create PR via GH CLI
              gh pr create \
                --repo "$target_full_path" \
                --base "main" \
                --head "$branch_name" \
                --title "Update README (Automated)" \
                --body "Automatic update of README.md generated from the central repository $GITHUB_REPOSITORY."
              
              echo "PR created successfully for $target_repo"
            fi
            
            # Return to root for next iteration
            cd ../..
          }

          # 3. Execution Loop
          for item in "${DEPLOYMENTS[@]}"; do
            repo="${item%%|*}"
            src="${item##*|}"
            process_repo "$repo" "$src"
          done
```

## Key Configuration Steps

- Update GH_HOST: Change github.your-company.com to your actual GitHub Enterprise Server URL.
- Update TARGET_ORG: Set this to "orgaB".
- Update the List: In the if [ "$INPUT_REPO" == "all" ]; block, update the lines DEPLOYMENTS+=("...") with your actual repository names.

## How it works

- Dynamic Input: You run the workflow manually. You type "all" or a specific repo name (e.g., "REPO_A").
- Source Selection:
  - If "all": It takes the standard readme.md and prepares to send it to every repo listed in the code.
  - If "REPO_A": It looks for readmeREPO_A.md in the source folder.
- Idempotency: The script runs git diff --quiet. If the target repo already has the exact same content as the source file, it skips the PR creation. This prevents spamming empty PRs.
- Pull Request: If the content differs, it creates a branch named update-readme-<timestamp> and opens a PR automatically.

```yaml 
name: Deploy Readme via PR

on:
  workflow_dispatch:
    inputs:
      target_repo_name:
        description: 'Target repo name (or "all")'
        required: true
        default: 'all'
        type: string

env:
  TARGET_ORG: "orgaB"
  GIT_USER_NAME: "GitHub Action Bot"
  GIT_USER_EMAIL: "bot@your-company.com"
  # IMPORTANT: Ensure this is just the domain (e.g., github.company.com), no https://
  GH_HOST: "github.your-company.com" 

jobs:
  distribute-readme:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Repo (sourceA)
        uses: actions/checkout@v3
        with:
          path: source_repo

      - name: Authenticate GitHub CLI & Configure Git
        run: |
          # 1. Authenticate the CLI
          echo "${{ secrets.PAT_TOKEN }}" | gh auth login --with-token --hostname ${{ env.GH_HOST }}
          
          # 2. CRITICAL FIX: Configure git to use GitHub CLI as the credential helper
          # This allows 'git push' to automatically use the token from 'gh'
          gh auth setup-git --hostname ${{ env.GH_HOST }}
          
          # 3. Global Git config for the bot identity
          git config --global user.name "${{ env.GIT_USER_NAME }}"
          git config --global user.email "${{ env.GIT_USER_EMAIL }}"

      - name: Process Deployment
        shell: bash
        env:
          GH_TOKEN: ${{ secrets.PAT_TOKEN }}
          INPUT_REPO: ${{ inputs.target_repo_name }}
        run: |
          declare -a DEPLOYMENTS
          SOURCE_DIR="$GITHUB_WORKSPACE/source_repo"

          if [ "$INPUT_REPO" == "all" ]; then
            echo "Mode: Global deployment (ALL)"
            # List of targets
            DEPLOYMENTS+=("REPO_A|readme.md")
            DEPLOYMENTS+=("REPO_B|readme.md")
            DEPLOYMENTS+=("REPO_C|readme.md")
          else
            echo "Mode: Targeted deployment for $INPUT_REPO"
            SPECIFIC_SOURCE="readme${INPUT_REPO}.md"
            
            if [ ! -f "$SOURCE_DIR/$SPECIFIC_SOURCE" ]; then
              echo "::error::Source file $SPECIFIC_SOURCE does not exist."
              exit 1
            fi
            DEPLOYMENTS+=("$INPUT_REPO|$SPECIFIC_SOURCE")
          fi

          process_repo() {
            local target_repo=$1
            local source_file_name=$2
            local target_full_path="$TARGET_ORG/$target_repo"
            local branch_name="update-readme-$(date +%s)" 

            echo "---------------------------------------------------"
            echo "Processing: $target_full_path"

            rm -rf temp_work_dir
            mkdir temp_work_dir
            cd temp_work_dir

            # Clone using GH CLI (uses auth from step above)
            gh repo clone "$target_full_path" . || { echo "Failed to clone"; return; }

            git checkout -b "$branch_name"
            cp "$SOURCE_DIR/$source_file_name" ./readme.md

            if git diff --quiet; then
              echo "No changes detected. Skipping."
            else
              echo "Changes detected. Committing..."
              git add readme.md
              git commit -m "docs: update README from sourceA"
              
              # This 'git push' will now succeed because of 'gh auth setup-git'
              echo "Pushing branch..."
              git push origin "$branch_name"

              echo "Creating PR..."
              gh pr create \
                --repo "$target_full_path" \
                --base "main" \
                --head "$branch_name" \
                --title "Update README (Automated)" \
                --body "Automatic update of README.md generated from $GITHUB_REPOSITORY."
              
              echo "Success!"
            fi
            cd ../..
          }

          for item in "${DEPLOYMENTS[@]}"; do
            repo="${item%%|*}"
            src="${item##*|}"
            process_repo "$repo" "$src"
          done
```          






          
