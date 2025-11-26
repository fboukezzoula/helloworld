```
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
          echo "${{ secrets.PAT_TOKEN }}" | gh auth login --with-token --hostname ${{ env.GH_HOST }}
          gh auth setup-git --hostname ${{ env.GH_HOST }}
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

            gh repo clone "$target_full_path" . || { echo "Failed to clone"; return; }

            git checkout -b "$branch_name"
            
            # 1. Copy the generic source file to readme.md
            cp "$SOURCE_DIR/$source_file_name" ./readme.md

            # 2. REPLACE ALL PLACEHOLDERS
            # The 'g' at the end ensures all instances on a line are replaced.
            # sed applies this to every line in the file.
            echo "Injecting repo name: $target_repo into all {{REPO_NAME}} placeholders"
            
            sed -i "s/{{REPO_NAME}}/$target_repo/g" ./readme.md

            # 3. Check for diffs
            if git diff --quiet; then
              echo "No changes detected (after variable replacement). Skipping."
            else
              echo "Changes detected. Committing..."
              git add readme.md
              git commit -m "docs: update README ($target_repo)"
              
              git push origin "$branch_name"

              echo "Creating PR..."
              gh pr create \
                --repo "$target_full_path" \
                --base "main" \
                --head "$branch_name" \
                --title "Update README for $target_repo" \
                --body "Automatic update of README.md. Repository name injected: $target_repo."
              
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
