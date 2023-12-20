// This workflow is used interactively when we want to trigger a new release.
// Most of the release is automated thanks to this workflow and release.jsonnet
// which is triggered when start-release.jsonnet creates a PR for a new release.
// See also the 'release:' rule in the toplevel Makefile which is used here to
// prepare the release branch and scripts/release/ which contains helper scripts
// for the release (e.g., towncrier to manage the changelog).

// TODO:
//  - factorize, lots of repeated content still
//  - remove intermediate SEMGREP_RELEASE_NEXT_VERSION, use ref to the step instead

local semgrep = import 'libs/semgrep.libsonnet';

// ----------------------------------------------------------------------------
// The jobs
// ----------------------------------------------------------------------------
// This job just infers the next release version (e.g., 1.53.1) based on past git
// tags in the semgrep repo and the workflow input choice (feature vs bug) and
// using christian-draeger/increment-semantic-version to compute it.
local get_version_job = {
  'runs-on': 'ubuntu-20.04',
  outputs: {
    version: '${{ steps.next-version.outputs.next-version }}',
  },
  steps: [
    semgrep.github_bot.get_jwt_step,
    semgrep.github_bot.get_token_step,
    {
      uses: 'actions/checkout@v3',
      with: {
        submodules: 'recursive',
        ref: '${{ github.event.repository.default_branch }}',
        token: '${{ steps.token.outputs.token }}',
      },
    },
    // Note that checkout@v3 does not get the tags by default. It does if you do
    // "full" checkout, which is too heavyweight. We don't want all branches and
    // everything that ever existed on the repo, so we just do a lightweight checkout
    // and then get the tags ourselves. Also we don't need the tags in submodules.
    {
      name: 'Pull Tags',
      run: "git fetch --no-recurse-submodules origin 'refs/tags/*:refs/tags/*'",
    },
    {
      name: 'Get latest version',
      id: 'latest-version',
      run: |||
        LATEST_TAG=$(git tag --list "v*.*.*" | sort -V | tail -n 1 | cut -c 2- )
        echo "latest-version=${LATEST_TAG}" >> $GITHUB_OUTPUT
      |||,
    },
    {
      name: 'Bump release version',
      id: 'next-version',
      uses: 'christian-draeger/increment-semantic-version@68f14f806a9800fe17433287c35226fd8fd60201',
      with: {
        'current-version': '${{ steps.latest-version.outputs.latest-version }}',
        'version-fragment': '${{ github.event.inputs.bumpVersionFragment }}',
      },
    },
  ],
};

// make sure semgrep-pro was released and that we have the right
// semgrep-core-proprietary in the right S3 bucket
local check_semgrep_pro_job = {
  needs: [
    'get-version',
  ],
  name: 'Check Semgrep Pro Manifest',
  secrets: 'inherit',
  uses: './.github/workflows/check-semgrep-pro-version.yml',
  with: {
    'bucket-name': 'deep-semgrep-artifacts',
    'manifest-key': 'versions-manifest.json',
    'semgrep-version': '${{ needs.get-version.outputs.version }}',
    'dry-run': '${{ inputs.dry-run }}',
  },
};

// make the Release PR
local release_setup_job = {
  needs: [
    'get-version',
    'check-semgrep-pro',
  ],
  'runs-on': 'ubuntu-20.04',
  outputs: {
    'pr-number': '${{ steps.open-pr.outputs.pr-number }}',
    'release-branch': '${{ steps.release-branch.outputs.release-branch }}',
  },
  steps: [
    semgrep.github_bot.get_jwt_step,
    semgrep.github_bot.get_token_step,
    {
      uses: 'actions/checkout@v3',
      with: {
        submodules: 'recursive',
        ref: '${{ github.event.repository.default_branch }}',
        token: '${{ steps.token.outputs.token }}',
      },
    },
    {
      name: 'Create release branch',
      id: 'release-branch',
      run: |||
        RELEASE_BRANCH="release-${{ needs.get-version.outputs.version }}"
        git checkout -b ${RELEASE_BRANCH}
        echo "release-branch=${RELEASE_BRANCH}" >> $GITHUB_OUTPUT
      |||,
    },
    {
      env: {
        SEMGREP_RELEASE_NEXT_VERSION: '${{ needs.get-version.outputs.version }}',
      },
      run: 'make release',
    },
    // for towncrier
    {
      uses: 'actions/setup-python@v4',
      with: {
        'python-version': '3.10',
        cache: 'pipenv',
        'cache-dependency-path': 'scripts/release/Pipfile.lock',
      },
    },
    {
      name: 'Create GitHub Release Body',
      'if': '${{ ! inputs.dry-run }}',
      'working-directory': 'scripts/release',
      run: |||
        pip3 install pipenv==2022.6.7
        pipenv install --dev
        pipenv run towncrier build --draft --version ${{ needs.get-version.outputs.version }} > release_body.txt
      |||,
    },
    {
      name: 'Upload Changelog Body Artifact',
      'if': '${{ ! inputs.dry-run }}',
      uses: 'actions/upload-artifact@v3',
      with: {
        name: 'release_body_${{ needs.get-version.outputs.version }}',
        path: 'scripts/release/release_body.txt',
      },
    },
    {
      name: 'Update Changelog',
      'working-directory': 'scripts/release',
      // use || true below since modifications mean exit code != 0
      run: |||
        pip3 install pipenv==2022.6.7
        pipenv install --dev
        pipenv run towncrier build --yes --version ${{ needs.get-version.outputs.version }}
        pipenv run pre-commit run --files ../../CHANGELOG.md --config ../../.pre-commit-config.yaml || true
      |||,
    },
    {
      name: 'Push release branch',
      'if': '${{ ! inputs.dry-run }}',
      env: {
        SEMGREP_RELEASE_NEXT_VERSION: '${{ needs.get-version.outputs.version }}',
      },
      run: |||
        git config user.name ${{ github.actor }}
        git config user.email ${{ github.actor }}@users.noreply.github.com
        git add --all
        git commit -m "chore: Bump version to ${SEMGREP_RELEASE_NEXT_VERSION}"
        git push --set-upstream origin ${{ steps.release-branch.outputs.release-branch }}
      |||,
    },
    {
      name: 'Create PR',
      'if': '${{ ! inputs.dry-run }}',
      id: 'open-pr',
      env: {
        SOURCE: '${{ steps.release-branch.outputs.release-branch }}',
        TARGET: '${{ github.event.repository.default_branch }}',
        TITLE: 'Release Version ${{ needs.get-version.outputs.version }}',
        GITHUB_TOKEN: '${{ steps.token.outputs.token }}',
      },
      run: |||
        # check if the branch already has a pull request open

        if gh pr list --head ${SOURCE} | grep -vq "no pull requests"; then
            # pull request already open
            echo "pull request from SOURCE ${SOURCE} to TARGET ${TARGET} is already open";
            echo "cancelling release"
            exit 1
        fi

        # open new pull request with the body of from the local template.
        PR_URL=$(gh pr create --title "${TITLE}" --body-file ./.github/PULL_REQUEST_TEMPLATE/release_pr_template.md \
          --base "${TARGET}" --head "${SOURCE}")

        echo $PR_URL

        # GHA doesn't provide an easy way to determine this, so we
        # capture the number and go from there.
        PR_NUMBER=$(echo $PR_URL | sed 's|.*pull/\(.*\)|\1|')

        echo "pr-number=$PR_NUMBER" >> $GITHUB_OUTPUT
      |||,
    },
  ],
};

local wait_for_pr_checks_job = {
  'if': '${{ ! inputs.dry-run }}',
  'runs-on': 'ubuntu-20.04',
  needs: [
    'get-version',
    'check-semgrep-pro',
    'release-setup',
  ],
  outputs: {
    'num-checks': '${{ steps.num-checks.outputs.num-checks }}',
  },
  steps: [
    {
      name: 'Wait for checks to register',
      env: {
        GITHUB_TOKEN: '${{ secrets.GITHUB_TOKEN }}',
      },
      run: |||
        LEN_CHECKS=$(gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup --jq '.statusCheckRollup | length');

        # Immediately after creation, the PR doesn't have any checks attached
        # yet, wait until this is not the case. If you immediately start waiting
        # for checks, then it just fails saying there's no checks.
          while [ ${LEN_CHECKS} = "0" ]; do
            echo "No checks available yet"
            sleep 1
            LEN_CHECKS=$(gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup --jq '.statusCheckRollup | length');
          done
          echo "checks are valid"

          echo ${LEN_CHECKS}

          gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup
      |||,
    },
    {
      name: 'Wait for checks to complete',
      id: 'wait-checks',
      env: {
        GITHUB_TOKEN: '${{ secrets.GITHUB_TOKEN }}',
      },
      // Wait for PR checks to finish
      run: 'gh pr -R returntocorp/semgrep checks "${{ needs.release-setup.outputs.pr-number }}" --interval 90 --watch',
    },
    {
      name: 'Get Current Num Checks',
      id: 'num-checks',
      env: {
        GITHUB_TOKEN: '${{ secrets.GITHUB_TOKEN }}',
      },
      // Once all checks are complete on the PR, find the number of checks
      // so that we can wait for the new checks to register. We can't do this
      // above because sometimes all checks aren't yet ready by the time the
      // first one is, so we end up in a case where we aren't getting waiting
      // for all checks.
      run: |||
        LEN_CHECKS=$(gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup --jq '.statusCheckRollup | length');
        echo "num-checks=${LEN_CHECKS}" >> $GITHUB_OUTPUT
      |||,
    },
  ],
};

local create_tag_job = {
  'if': '${{ ! inputs.dry-run }}',
  'runs-on': 'ubuntu-20.04',
  needs: [
    'get-version',
    'check-semgrep-pro',
    'release-setup',
    'wait-for-pr-checks',
  ],
  steps: [
    semgrep.github_bot.get_jwt_step,
    semgrep.github_bot.get_token_step,
    {
      uses: 'actions/checkout@v3',
      with: {
        submodules: true,
        ref: '${{ needs.release-setup.outputs.release-branch }}',
        token: '${{ steps.token.outputs.token }}',
      },
    },
    {
      name: 'Create semgrep release version tag',
      run: |||
        git config user.name ${{ github.actor }}
        git config user.email ${{ github.actor }}@users.noreply.github.com
        git tag -a -m "Release ${{ needs.get-version.outputs.version }}" "v${{ needs.get-version.outputs.version }}"
        git push origin "v${{ needs.get-version.outputs.version }}"
      |||,
    },
    {
      name: 'Create semgrep-interfaces release version tag',
      run: |||
        cd cli/src/semgrep/semgrep_interfaces
        git config user.name ${{ github.actor }}
        git config user.email ${{ github.actor }}@users.noreply.github.com
        git tag -a -m "Release ${{ needs.get-version.outputs.version }}" "v${{ needs.get-version.outputs.version }}"
        git push origin "v${{ needs.get-version.outputs.version }}"
      |||,
    },
  ],
};

local create_draft_release_job = {
  'if': '${{ ! inputs.dry-run }}',
  'runs-on': 'ubuntu-20.04',
  needs: [
    'get-version',
    'release-setup',
    'create-tag',
    'wait-for-pr-checks',
  ],
  steps: [
    {
      name: 'Download Release Body Artifact',
      uses: 'actions/download-artifact@v3',
      with: {
        name: 'release_body_${{ needs.get-version.outputs.version }}',
        path: 'scripts/release',
      },
    },
    {
      name: 'Create Draft Release Semgrep',
      uses: 'softprops/action-gh-release@v1',
      with: {
        tag_name: 'v${{ needs.get-version.outputs.version }}',
        name: 'Release v${{ needs.get-version.outputs.version }}',
        body_path: 'scripts/release/release_body.txt',
        token: '${{ secrets.GITHUB_TOKEN }}',
        prerelease: false,
        draft: true,
      },
    },
    semgrep.github_bot.get_jwt_step,
    semgrep.github_bot.get_token_step,
    {
      name: 'Create Draft Release Semgrep Interfaces',
      uses: 'softprops/action-gh-release@v1',
      with: {
        tag_name: 'v${{ needs.get-version.outputs.version }}',
        name: 'Release v${{ needs.get-version.outputs.version }}',
        body_path: 'scripts/release/release_body.txt',
        token: '${{ steps.token.outputs.token }}',
        prerelease: false,
        draft: true,
        repository: 'returntocorp/semgrep-interfaces',
      },
    },
  ],
};

local wait_for_release_checks_job = {
  'if': '${{ ! inputs.dry-run }}',
  'runs-on': 'ubuntu-20.04',
  needs: [
    'release-setup',
    'wait-for-pr-checks',
    'create-tag',
  ],
  steps: [
    {
      name: 'Wait for release checks to register',
      id: 'register-release-checks',
      env: {
        GITHUB_TOKEN: '${{ secrets.GITHUB_TOKEN }}',
      },
      run: |||
        LEN_CHECKS=$(gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup --jq '.statusCheckRollup | length');

        # We need to wait for the new checks to register when the release tag is pushed
        while [ ${LEN_CHECKS} = ${{ needs.wait-for-pr-checks.outputs.num-checks }} ]; do
          echo "No checks available yet"
          sleep 1
          LEN_CHECKS=$(gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup --jq '.statusCheckRollup | length');
        done
        echo "checks are valid"

        echo ${LEN_CHECKS}

        gh pr -R returntocorp/semgrep view "${{ needs.release-setup.outputs.pr-number }}" --json statusCheckRollup
      |||,
    },
    {
      name: 'Wait for release checks',
      id: 'wait-release-checks',
      env: {
        GITHUB_TOKEN: '${{ secrets.GITHUB_TOKEN }}',
      },
      // # Wait for PR checks to finish
      run: 'gh pr -R returntocorp/semgrep checks "${{ needs.release-setup.outputs.pr-number }}" --interval 90 --watch',
    },
  ],
};

local validate_release_trigger_job = {
  'if': '${{ ! inputs.dry-run }}',
  needs: [
    'get-version',
    'wait-for-release-checks',
    'release-setup',
  ],
  uses: './.github/workflows/validate-release.yml',
  secrets: 'inherit',
  with: {
    version: '${{needs.get-version.outputs.version}}',
  },
};

local bump_semgrep_app_job = {
  'if': '${{ ! inputs.dry-run }}',
  needs: [
    'get-version',
    'validate-release-trigger',
    'release-setup',
  ],
  uses: './.github/workflows/call-bump-pr-workflow.yml',
  secrets: 'inherit',
  with: {
    version: '${{needs.get-version.outputs.version}}',
    repository: 'semgrep/semgrep-app',
  },
};

local bump_semgrep_action_job = {
  'if': '${{ ! inputs.dry-run }}',
  needs: [
    'get-version',
    'validate-release-trigger',
    'release-setup',
  ],
  uses: './.github/workflows/call-bump-pr-workflow.yml',
  secrets: 'inherit',
  with: {
    version: '${{needs.get-version.outputs.version}}',
    repository: 'semgrep/semgrep-action',
  },
};

local bump_semgrep_rpc_job = {
  'if': '${{ ! inputs.dry-run }}',
  needs: [
    'get-version',
    'validate-release-trigger',
    'release-setup',
  ],
  uses: './.github/workflows/call-bump-pr-workflow.yml',
  secrets: 'inherit',
  with: {
    version: '${{needs.get-version.outputs.version}}',
    repository: 'semgrep/semgrep-rpc',
  },
};

// ----------------------------------------------------------------------------
// Success/failure notifications
// ----------------------------------------------------------------------------

local notify_success_job = {
  'if': '${{ success() && ! inputs.dry-run }}',
  needs: [
    'get-version',
    'release-setup',
    'validate-release-trigger',
    'bump-semgrep-action',
    'bump-semgrep-rpc',
    'bump-semgrep-app',
  ],
  'runs-on': 'ubuntu-20.04',
  steps: [
    {
      run: 'echo "${{needs.get-version.outputs.version}}"',
    },
    {
      name: 'Notify Success',
      run: |||
        # POST a webhook to Zapier to allow for public notifications to our users via Twitter
        curl "${{ secrets.ZAPIER_WEBHOOK_URL }}" \
          -d '{"version":"${{needs.get-version.outputs.version}}","changelog_url":"https://github.com/returntocorp/semgrep/releases/tag/v${{needs.get-version.outputs.version}}"}'

        curl --request POST \
        --url  ${{ secrets.NOTIFICATIONS_URL }} \
        --header 'content-type: application/json' \
        --data '{
          "version": "${{needs.get-version.outputs.version}}",
          "message": "Release Validation has succeeded! Please review the PRs in semgrep-app, semgrep-rpc, and semgrep-action that were generated by this workflow."
        }'
      |||,
    },
  ],
};

local notify_failure_job = {
  'if': '${{ failure() && ! inputs.dry-run }}',
  needs: [
    'get-version',
    'release-setup',
    'validate-release-trigger',
    'bump-semgrep-action',
    'bump-semgrep-rpc',
    'bump-semgrep-app',
  ],
  'runs-on': 'ubuntu-20.04',
  steps: [
    {
      name: 'Notify Failure',
      run: |||
        curl --request POST \
        --url  ${{ secrets.NOTIFICATIONS_URL }} \
        --header 'content-type: application/json' \
        --data '{
          "version": "${{needs.get-version.outputs.version}}",
          "message": "Release Validation has failed. Please see https://github.com/${{github.repository}}/actions/runs/${{github.run_id}} for more details!"
        }'
      |||,
    },
  ],
};

// ----------------------------------------------------------------------------
// The Workflow
// ----------------------------------------------------------------------------

{
  name: 'start-release',
  on: {
    workflow_dispatch: {
      inputs: {
        bumpVersionFragment: {
          description: 'Version fragment to bump',
          required: true,
          // These options are passed directly into
          // christian-draeger/increment-semantic-version in the `next-vesion`
          // step to decide which of X.Y.Z to increment
          type: 'choice',
          options: [
            // Many folks are concerned about a mis-click and releasing 2.0 which
            // is why we commented the 'major' option below
            // 'major', // x.0.0
            'feature',  // 1.x.0
            'bug',  // 1.1.x
          ],
          default: 'feature',
        },
        'dry-run': {
          required: true,
          type: 'boolean',
          description: |||
            Check the box for a dry-run - A dry-run will not push any external state
            (branches, tags, images, or PyPI packages).
          |||,
          default: false,
        },
      },
    },
  },
  jobs: {
    'get-version': get_version_job,
    'check-semgrep-pro': check_semgrep_pro_job,
    'release-setup': release_setup_job,
    'wait-for-pr-checks': wait_for_pr_checks_job,
    'create-tag': create_tag_job,
    'create-draft-release': create_draft_release_job,
    'wait-for-release-checks': wait_for_release_checks_job,
    'validate-release-trigger': validate_release_trigger_job,
    'bump-semgrep-app': bump_semgrep_app_job,
    'bump-semgrep-action': bump_semgrep_action_job,
    'bump-semgrep-rpc': bump_semgrep_rpc_job,
    'notify-success': notify_success_job,
    'notify-failure': notify_failure_job,
  },
}