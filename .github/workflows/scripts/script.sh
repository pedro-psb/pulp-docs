#!/usr/bin/env bash
# coding=utf-8

# WARNING: DO NOT EDIT!
#
# This file was generated by plugin_template, and is managed by it. Please use
# './plugin-template --github pulp_docs' to update this file.
#
# For more info visit https://github.com/pulp/plugin_template

set -mveuo pipefail

# make sure this script runs at the repo root
cd "$(dirname "$(realpath -e "$0")")"/../../..

source .github/workflows/scripts/utils.sh

export POST_SCRIPT=$PWD/.github/workflows/scripts/post_script.sh
export POST_DOCS_TEST=$PWD/.github/workflows/scripts/post_docs_test.sh
export FUNC_TEST_SCRIPT=$PWD/.github/workflows/scripts/func_test_script.sh

# Needed for both starting the service and building the docs.
# Gets set in .github/settings.yml, but doesn't seem to inherited by
# this script.
export DJANGO_SETTINGS_MODULE=pulpcore.app.settings
export PULP_SETTINGS=$PWD/.ci/ansible/settings/settings.py

export PULP_URL="https://pulp"

if [[ "$TEST" = "docs" ]]; then
  if [[ "$GITHUB_WORKFLOW" == "Pulp-Docs CI" ]]; then
    towncrier build --yes --version 4.0.0.ci
  fi
  cd docs
  make PULP_URL="$PULP_URL" diagrams html
  tar -cvf docs.tar ./_build
  cd ..

  if [ -f "$POST_DOCS_TEST" ]; then
    source "$POST_DOCS_TEST"
  fi
  exit
fi

if [[ "$TEST" = "new_docs" ]]; then
  pip install --user git+https://github.com/pulp/pulp-docs
  pulp-docs build
  exit
fi

REPORTED_STATUS="$(pulp status)"

echo "machine pulp
login admin
password password
" | cmd_user_stdin_prefix bash -c "cat >> ~pulp/.netrc"
# Some commands like ansible-galaxy specifically require 600
cmd_prefix bash -c "chmod 600 ~pulp/.netrc"

# Generate and install binding
pushd ../pulp-openapi-generator
if pulp debug has-plugin --name "core" --specifier ">=3.44.0.dev"
then
  # Use app_label to generate api.json and package to produce the proper package name.

  if [ "$(jq -r '.domain_enabled' <<<"$REPORTED_STATUS")" = "true" ]
  then
    # Workaround: Domains are not supported by the published bindings.
    # Generate new bindings for all packages.
    for item in $(jq -r '.versions[] | tojson' <<<"$REPORTED_STATUS")
    do
      echo $item
      COMPONENT="$(jq -r '.component' <<<"$item")"
      VERSION="$(jq -r '.version' <<<"$item")"
      MODULE="$(jq -r '.module' <<<"$item")"
      PACKAGE="${MODULE%%.*}"
      curl --fail-with-body -k -o api.json "${PULP_URL}${PULP_API_ROOT}api/v3/docs/api.json?bindings&component=$COMPONENT"
      USE_LOCAL_API_JSON=1 ./generate.sh "${PACKAGE}" python "${VERSION}"
      cmd_prefix pip3 install "/root/pulp-openapi-generator/${PACKAGE}-client"
      sudo rm -rf "./${PACKAGE}-client"
    done
  else
    # Sadly: Different pulpcore-versions aren't either...
    for item in $(jq -r '.versions[]| select(.component!="pulp-docs")| tojson' <<<"$REPORTED_STATUS")
    do
      echo $item
      COMPONENT="$(jq -r '.component' <<<"$item")"
      VERSION="$(jq -r '.version' <<<"$item")"
      MODULE="$(jq -r '.module' <<<"$item")"
      PACKAGE="${MODULE%%.*}"
      curl --fail-with-body -k -o api.json "${PULP_URL}${PULP_API_ROOT}api/v3/docs/api.json?bindings&component=$COMPONENT"
      USE_LOCAL_API_JSON=1 ./generate.sh "${PACKAGE}" python "${VERSION}"
      cmd_prefix pip3 install "/root/pulp-openapi-generator/${PACKAGE}-client"
      sudo rm -rf "./${PACKAGE}-client"
    done
  fi
else
  # Infer the client name from the package name by replacing "-" with "_".
  # Use the component to infer the package name on older versions of pulpcore.

  if [ "$(echo "$REPORTED_STATUS" | jq -r '.domain_enabled')" = "true" ]
  then
    # Workaround: Domains are not supported by the published bindings.
    # Generate new bindings for all packages.
    for item in $(echo "$REPORTED_STATUS" | jq -r '.versions[]|(.package // ("pulp_" + .component)|sub("pulp_core"; "pulpcore"))|sub("-"; "_")')
    do
      ./generate.sh "${item}" python
      cmd_prefix pip3 install "/root/pulp-openapi-generator/${item}-client"
      sudo rm -rf "./${item}-client"
    done
  else
    # Sadly: Different pulpcore-versions aren't either...
    for item in $(echo "$REPORTED_STATUS" | jq -r '.versions[]|select(.component!="pulp-docs")|(.package // ("pulp_" + .component)|sub("pulp_core"; "pulpcore"))|sub("-"; "_")')
    do
      ./generate.sh "${item}" python
      cmd_prefix pip3 install "/root/pulp-openapi-generator/${item}-client"
      sudo rm -rf "./${item}-client"
    done
  fi
fi
popd

# At this point, this is a safeguard only, so let's not make too much fuzz about the old status format.
echo "$REPORTED_STATUS" | jq -r '.versions[]|select(.package)|(.package|sub("_"; "-")) + "-client==" + .version' > bindings_requirements.txt
cmd_stdin_prefix bash -c "cat > /tmp/unittest_requirements.txt" < unittest_requirements.txt
cmd_stdin_prefix bash -c "cat > /tmp/functest_requirements.txt" < functest_requirements.txt
cmd_stdin_prefix bash -c "cat > /tmp/bindings_requirements.txt" < bindings_requirements.txt
cmd_prefix pip3 install -r /tmp/unittest_requirements.txt -r /tmp/functest_requirements.txt -r /tmp/bindings_requirements.txt

CERTIFI=$(cmd_prefix python3 -c 'import certifi; print(certifi.where())')
cmd_prefix bash -c "cat /etc/pulp/certs/pulp_webserver.crt >> '$CERTIFI'"

# check for any uncommitted migrations
echo "Checking for uncommitted migrations..."
cmd_user_prefix bash -c "django-admin makemigrations pulp-docs --check --dry-run"

# Run unit tests.
cmd_user_prefix bash -c "PULP_DATABASES__default__USER=postgres pytest -v -r sx --color=yes --suppress-no-test-exit-code -p no:pulpcore --pyargs pulp_docs.tests.unit"
# Run functional tests
if [[ "$TEST" == "performance" ]]; then
  if [[ -z ${PERFORMANCE_TEST+x} ]]; then
    cmd_user_prefix bash -c "pytest -vv -r sx --color=yes --suppress-no-test-exit-code --capture=no --durations=0 --pyargs pulp_docs.tests.performance"
  else
    cmd_user_prefix bash -c "pytest -vv -r sx --color=yes --suppress-no-test-exit-code --capture=no --durations=0 --pyargs pulp_docs.tests.performance.test_${PERFORMANCE_TEST}"
  fi
  exit
fi

if [ -f "$FUNC_TEST_SCRIPT" ]; then
  source "$FUNC_TEST_SCRIPT"
else
  if [[ "$GITHUB_WORKFLOW" =~ "Nightly" ]]
  then
    cmd_user_prefix bash -c "pytest -v -r sx --color=yes --suppress-no-test-exit-code --pyargs pulp_docs.tests.functional -m parallel -n 8 --nightly"
    cmd_user_prefix bash -c "pytest -v -r sx --color=yes --suppress-no-test-exit-code --pyargs pulp_docs.tests.functional -m 'not parallel' --nightly"
  else
    cmd_user_prefix bash -c "pytest -v -r sx --color=yes --suppress-no-test-exit-code --pyargs pulp_docs.tests.functional -m parallel -n 8"
    cmd_user_prefix bash -c "pytest -v -r sx --color=yes --suppress-no-test-exit-code --pyargs pulp_docs.tests.functional -m 'not parallel'"
  fi 
fi

if [ -f "$POST_SCRIPT" ]; then
  source "$POST_SCRIPT"
fi
