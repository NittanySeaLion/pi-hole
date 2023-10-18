#!/usr/bin/env sh
# shellcheck disable=SC1090

# Ignore warning about `local` being undefinded in POSIX
# shellcheck disable=SC3043
# https://github.com/koalaman/shellcheck/wiki/SC3043#exceptions

# Pi-hole: A black hole for Internet advertisements
# (c) 2023 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Search Adlists
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# Globals
PI_HOLE_INSTALL_DIR="/opt/pihole"
max_results="20"
partial="false"
domain=""

# Source color table
colfile="/opt/pihole/COL_TABLE"
. "${colfile}"

# Source api functions
. "${PI_HOLE_INSTALL_DIR}/api.sh"

Help(){
    echo "Usage: pihole -q [option] <domain>
Example: 'pihole -q --partial domain.com'
Query the adlists for a specified domain

Options:
  --partial            Search the adlists for partially matching domains
  --all                Return all query matches within the adlists
  -h, --help           Show this help dialog"
  exit 0
}


GenerateOutput(){
    local data gravity_data lists_data num_gravity num_lists search_type_str
    local gravity_data_csv lists_data_csv line current_domain
    data="${1}"

    # construct a new json for the list results where each object contains the domain and the related type
    lists_data=$(echo "${data}" | jq '.search.domains | [.[] | {domain: .domain, type: .type}]')

    # construct a new json for the gravity results where each object contains the adlist URL and the related domains
    gravity_data=$(echo "${data}" | jq '.search.gravity  | group_by(.address) | map({ address: (.[0].address), domains: [.[] | .domain] })')

    # number of objects in each json
    num_gravity=$(echo "${gravity_data}" | jq length )
    num_lists=$(echo "${lists_data}" | jq length )

    if [ "${partial}" = true ]; then
      search_type_str="partially"
    else
      search_type_str="exactly"
    fi

    # Results from allow/deny list
    printf "%s\n\n" "Found ${num_lists} domains ${search_type_str} matching '${COL_BLUE}${domain}${COL_NC}'."
    if [ "${num_lists}" -gt 0 ]; then
        # Convert the data to a csv, each line is a "domain,type" string
        # not using jq's @csv here as it quotes each value individually
        lists_data_csv=$(echo "${lists_data}" | jq --raw-output '.[] | [.domain, .type] | join(",")' )

        # Generate output for each csv line, separating line in a domain and type substring at the ','
        echo "${lists_data_csv}" | while read -r line; do
            printf "%s\n\n" "  - ${COL_GREEN}${line%,*}${COL_NC} (type: exact ${line#*,} domain)"
        done
    fi

    # Results from gravity
    printf "%s\n\n" "Found ${num_gravity} adlists ${search_type_str} matching '${COL_BLUE}${domain}${COL_NC}'."
    if [ "${num_gravity}" -gt 0 ]; then
        # Convert the data to a csv, each line is a "URL,domain,domain,...." string
        # not using jq's @csv here as it quotes each value individually
        gravity_data_csv=$(echo "${gravity_data}" | jq --raw-output '.[] | [.address, .domains[]] | join(",")' )

        # Generate line-by-line output for each csv line
        echo "${gravity_data_csv}" | while read -r line; do

            # print adlist URL
            printf "%s\n\n" "  - ${COL_BLUE}${line%%,*}${COL_NC}"

            # cut off URL, leaving "domain,domain,...."
            line=${line#*,}
            # print each domain and remove it from the string until nothing is left
            while  [ ${#line} -gt 0 ]; do
                current_domain=${line%%,*}
                printf '    - %s\n' "${COL_GREEN}${current_domain}${COL_NC}"
                # we need to remove the current_domain and the comma in two steps because
                # the last domain won't have a trailing comma and the while loop wouldn't exit
                line=${line#"${current_domain}"}
                line=${line#,}
            done
            printf "\n\n"
        done
    fi
}

Main(){
    local data

    if [ -z "${domain}" ]; then
        echo "No domain specified"; exit 1
    else
        # convert domain to punycode
        domain=$(idn2 "${domain}")

        # convert the domain to lowercase
        domain=$(echo "${domain}" | tr '[:upper:]' '[:lower:]')
    fi

    # Test if the authentication endpoint is available
    TestAPIAvailability

    # Users can configure FTL in a way, that for accessing a) all endpoints (webserver.api.localAPIauth)
    # or b) for the /search endpoint (webserver.api.searchAPIauth) no authentication is required.
    # Therefore, we try to query directly without authentication but do authenticat if 401 is returned

    data=$(GetFTLData "/search/${domain}?N=${max_results}&partial=${partial}")

    if [ "${data}" = 401 ]; then
        # Unauthenticated, so authenticate with the FTL server required
        Authenthication

        # send query again
        data=$(GetFTLData "/search/${domain}?N=${max_results}&partial=${partial}")
    fi

    GenerateOutput "${data}"
    DeleteSession
}

# Process all options (if present)
while [ "$#" -gt 0 ]; do
  case "$1" in
    "-h" | "--help"     ) Help;;
    "--partial"         ) partial="true";;
    "--all"             ) max_results=10000;; # hard-coded FTL limit
    *                   ) domain=$1;;
  esac
  shift
done

Main "${domain}"
