#!/usr/bin/env bash
# Host-authenticated v3 reviews and untrusted, jq-free snapshots. Source after common.sh, spec-lib.sh,
# review-policy-lib.sh and review-fingerprint-lib.sh. Bash 3.2, POSIX awk, local Git.
#
# review_receipts_policy ROOT POLICY_AT reads trusted config, setting RC_* policy and RC_ERROR.
# review_receipts_fetch URL ROOT WORK reads the host into WORK/receipts (RC_FILE), setting
# RC_REPO/PR/PR_HEAD/PR_CREATED/BASE/FETCHED/PR_AUTHOR, RC_IGNORED and RC_NOTES.
# review_receipts_read FILE WORK reads a snapshot with the same metadata and RC_FILE outputs.
# review_receipts_write FILE writes that normalized list. None of these evaluates coverage.
# review_receipts_scope CHANGE RIGOR REGISTRY WORK resolves foreign/carried blockers into
# RC_PROBLEMS and writes this PR's checked-change verdicts to RC_COVERAGE. Order is host order.
# R/X/O rows and the header are separated by ASCII US (037), not shell whitespace. The R row
# follows design §2 verbatim; review URLs are reconstructed from origin PR and host review id.
# The caller owns WORK and its cleanup. Errors return 1 with RC_ERROR, never partial evidence.
# shellcheck disable=SC2034,SC2016 # Public outputs and literal jq variables.

review_receipts_policy() {
    local root="$1" at="$2" key value kind item list
    RC_ERROR=""; RC_PUBLISHERS=""; RC_OWNERS=""; RC_ISOLATION=""; RC_NOTES=()
    if [ -z "$at" ] || ! git -C "$root" rev-parse --verify "$at^{commit}" >/dev/null 2>&1; then
        RC_ERROR='No trusted receipt policy commit; establish origin/HEAD with its history fetched'; return 1
    fi
    for key in review-host review-publishers review-owner review-publisher-isolation; do
        value="$( { git -C "$root" show "$at:.prdkit/memory/config.md" 2>/dev/null || true; } | awk "$SPEC_SKIP_AWK"'
            { if (spec_skip($0)) next }
            /^## / { section = $0; next }
            section == "## Configuration" && index($0, "- " key ":") == 1 {
                n++; value = substr($0, length(key) + 4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            }
            END { if (n == 1) print value }' key="$key")"
        case "$key" in
            review-host) [ "$value" = github ] || RC_ERROR='review-host must be github' ;;
            review-publisher-isolation)
                case "$value" in required|shared) RC_ISOLATION="$value" ;; *) RC_ERROR='review-publisher-isolation must be required or shared' ;; esac ;;
            *)
                list=""; kind=publisher; [ "$key" != review-owner ] || kind=owner
                if [[ "$value" =~ ^(bot|user):[1-9][0-9]*([[:space:]]*,[[:space:]]*(bot|user):[1-9][0-9]*)*$ ]]; then
                    list="$(printf '%s' "$value" | tr -d ' \t\r' | tr ',' '\n')"
                    if [ "$kind" = owner ]; then
                        while IFS= read -r item; do case "$item" in user:*) ;; *) list="" ;; esac; done <<< "$list"
                    fi
                fi
                [ -n "$list" ] || RC_ERROR="$key must be a non-empty numeric $kind list"
                if [ "$kind" = owner ]; then RC_OWNERS="$list"; else RC_PUBLISHERS="$list"; fi ;;
        esac
    done
    [ -z "$RC_ERROR" ] || { RC_ERROR="Trusted policy at $at: $RC_ERROR; fix .prdkit/memory/config.md on the integration branch"; return 1; }
}

_receipts_reviews() { # repo PR output-directory; validate the entire GraphQL stream
    local repo="$1" number="$2" work="$3" query
    query='query PrdkitReviews($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
      repository(owner:$owner,name:$name) { pullRequest(number:$number) {
        number author { __typename login ... on User { databaseId } ... on Bot { databaseId } }
        state headRefOid headRefName baseRefName createdAt merged
        reviews(first:100,after:$endCursor) { nodes {
          fullDatabaseId url body state submittedAt lastEditedAt editor { __typename login }
          author { __typename login ... on Bot { databaseId } ... on User { databaseId } } commit { oid }
        } pageInfo { hasNextPage endCursor } }
      } }
    }'
    if ! gh api graphql --hostname github.com --paginate -f query="$query" -F owner="${repo%/*}" -F name="${repo#*/}" -F number="$number" > "$work/pages-$number" 2>/dev/null; then
        RC_ERROR="could not read every review on PR $number"; return 1
    fi
    if ! jq -se --argjson number "$number" '
        def actor: type == "object" and (.login|type)=="string" and
            (.__typename|type)=="string" and (.databaseId|type)=="number";
        length > 0 and all(.[]; (.errors // [] | length)==0 and
            (.data.repository.pullRequest as $p | $p.number == $number and
             ($p.author|actor) and ($p.headRefOid|test("^[0-9a-f]{40}$")) and ($p.baseRefName|type)=="string" and
             ($p.headRefName|type)=="string" and ($p.merged|type)=="boolean" and
             ($p.reviews.nodes|type)=="array" and ($p.reviews.pageInfo.hasNextPage|type)=="boolean" and
             all($p.reviews.nodes[]; type=="object" and has("fullDatabaseId") and has("url") and has("body") and
                 has("author") and has("commit") and has("state") and has("submittedAt") and
                 has("lastEditedAt") and has("editor") and (.fullDatabaseId|tostring|test("^[1-9][0-9]*$")) and
                 (.url|type)=="string" and (.body|type)=="string" and
                 (.state=="PENDING" or (.submittedAt|type)=="string")))) and
        (.[-1].data.repository.pullRequest.reviews.pageInfo.hasNextPage == false) and
        ([.[].data.repository.pullRequest | del(.reviews)] | unique | length)==1 and
        ([range(0;length-1) as $i | .[$i].data.repository.pullRequest.reviews.pageInfo |
            .hasNextPage == true and (.endCursor|type)=="string" and (.endCursor|length)>0] | all) and
        ([.[].data.repository.pullRequest.reviews.pageInfo.endCursor | select(. != null)] as $c |
            ($c|unique|length)==($c|length))
        ' "$work/pages-$number" >/dev/null 2>&1; then
        RC_ERROR="incomplete or non-advancing review pages on PR $number"; return 1
    fi
    jq -s '{pr:.[0].data.repository.pullRequest | del(.reviews),
        reviews:[.[].data.repository.pullRequest.reviews.nodes[]]}' "$work/pages-$number" > "$work/source-$number.json"
}

_receipts_consistency() { # root change from to head since base base_at -> RC_ERROR
    local root="$1" change="$2" from="$3" to="$4" head="$5" since="$6" base="$7" base_at="$8" fp
    RC_ERROR=""
    git check-ref-format "$base" >/dev/null 2>&1 || { RC_ERROR='invalid base ref'; return 1; }
    if ! spec_objects_local "$root"; then
        RC_ERROR='receipt provenance cannot be checked without fetching from the promisor remote on this Git version'; return 1
    fi
    # Absent provenance is permitted; tokens remain authenticated. Never fetch it implicitly.
    if ! GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file -e "$base_at^{commit}" 2>/dev/null; then return 0; fi
    if [ "$to" != none ] && GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null; then
        if ! fp="$(review_fingerprint "$root" "$change" "$base_at" "$head")"; then RC_ERROR='cannot fingerprint the receipt head against base_at'; return 1; fi
        [ "$fp" = "$to" ] || { RC_ERROR="its to is not the content of its head ${head:0:12}; the publisher computed it against another base or is wrong; publish the verdict again"; return 1; }
    fi
    if [ -n "$since" ] && GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file -e "$since^{commit}" 2>/dev/null; then
        if ! fp="$(review_fingerprint "$root" "$change" "$base_at" "$since")"; then RC_ERROR='cannot fingerprint since against base_at'; return 1; fi
        [ "$fp" = "$from" ] || { RC_ERROR='its from is not the content of since against base_at; publish the verdict again'; return 1; }
    fi
}

review_receipts_fetch() { # URL root work; policy already read; caller supplies RC_RIGOR
    local url="$1" root="$2" work="$3" re source number head_label raw item error fields
    local change from to rhead since base base_at
    RC_ERROR=""; RC_IGNORED=0; RC_NOTES=(); RC_FILE="$work/receipts"
    re='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$'
    [[ "$url" =~ $re ]] || { RC_ERROR='--pr must be a github.com pull request URL'; return 1; }
    RC_REPO="${BASH_REMATCH[1]}"; RC_PR="${BASH_REMATCH[2]}"
    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then RC_ERROR='online receipts need gh and jq'; return 1; fi
    mkdir -p "$work" || return 1
    if ! gh api --hostname github.com "repos/$RC_REPO/pulls/$RC_PR" > "$work/pr.json" 2>/dev/null ||
        ! jq -e --argjson pr "$RC_PR" '.number==$pr and (.head.sha|test("^[0-9a-f]{40}$")) and
            (.head.label|type)=="string" and (.head.ref|type)=="string" and (.base.ref|type)=="string" and
            (.user.id|type)=="number" and (.created_at|type)=="string" and (.state=="open" or .state=="closed")' "$work/pr.json" >/dev/null 2>&1; then
        RC_ERROR='could not read the complete PR (offline, unauthorized or unavailable)'; return 1
    fi
    RC_PR_HEAD="$(jq -r .head.sha "$work/pr.json")"; RC_BASE="$(jq -r .base.ref "$work/pr.json")"
    RC_PR_AUTHOR="$(jq -r .user.id "$work/pr.json")"; RC_PR_CREATED="$(jq -r .created_at "$work/pr.json")"
    RC_FETCHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; head_label="$(jq -r '.head.label | @uri' "$work/pr.json")"
    if ! gh api --hostname github.com --paginate "repos/$RC_REPO/pulls?state=closed&head=$head_label" > "$work/closed" 2>/dev/null ||
        ! jq -se 'length>0 and all(.[]; type=="array" and all(.[]; (.number|type)=="number" and has("merged_at") and .state=="closed"))' "$work/closed" >/dev/null 2>&1; then
        RC_ERROR='could not enumerate closed source PRs completely'; return 1
    fi
    _receipts_reviews "$RC_REPO" "$RC_PR" "$work" || return 1
    if ! jq -e --arg head "$RC_PR_HEAD" --arg base "$RC_BASE" --arg author "$RC_PR_AUTHOR" '
        .pr.headRefOid==$head and .pr.baseRefName==$base and (.pr.author.databaseId|tostring)==$author' "$work/source-$RC_PR.json" >/dev/null; then
        RC_ERROR='PR metadata changed while enumerating reviews; retry'; return 1
    fi
    printf '%s\n' "$RC_PR" > "$work/prs"
    jq -sr --argjson current "$RC_PR" '[.[][] | .number | select(. != $current)] | unique[]' "$work/closed" >> "$work/prs"
    : > "$work/sources"
    while IFS= read -r number; do
        [ "$number" = "$RC_PR" ] || _receipts_reviews "$RC_REPO" "$number" "$work" || return 1
        if [ "$number" != "$RC_PR" ] && ! jq -e --arg ref "$(jq -r .head.ref "$work/pr.json")" \
            --argjson number "$number" --slurpfile closed "$work/closed" '
            ($closed | [.[][] | select(.number==$number) | (.merged_at!=null)] | unique) as $merged |
            ($merged|length)==1 and .pr.headRefName==$ref and .pr.merged==$merged[0] and
            .pr.state==(if $merged[0] then "MERGED" else "CLOSED" end)' "$work/source-$number.json" >/dev/null; then
            RC_ERROR="closed source PR $number changed while enumerating; retry"; return 1
        fi
        cat "$work/source-$number.json" >> "$work/sources"
    done < "$work/prs"
    # Classify every submitted publisher review, including malformed/edited bodies. Merged PRs
    # contribute restatements only. The publisher's numeric actor identity is the trust anchor.
    if ! jq -sc --arg repo "$RC_REPO" --arg publishers "$RC_PUBLISHERS" --arg isolation "$RC_ISOLATION" \
        --arg rigor "${RC_RIGOR:-unknown}" --argjson current "$RC_PR" '
        def clean_string: type=="string" and (test("[\\x00-\\x1f\\x7f]")|not);
        def hex40: type=="string" and test("^[0-9a-f]{40}$");
        def fp: type=="string" and test("^fp1:[0-9a-f]{64}$");
        def nat: type=="number" and .>=0 and floor==.;
        def blocking: .verdict=="FAIL" or .critical!=0 or .high!=0 or ($rigor!="light" and .medium!=0);
        def payload:
            reduce (split("\n")[] | rtrimstr("\r")) as $line
                ({starts:0,ends:0,inside:false,text:""};
                 if $line=="<!-- prdkit-review" then .starts+=1 | .inside=true
                 elif .inside and $line=="-->" then .ends+=1 | .inside=false
                 elif .inside then .text += $line+"\n" else . end) |
            . + {parsed:(try (.text|fromjson) catch null)};
        def schema_error($n):
            if type!="object" then "receipt JSON is not an object"
            elif .schema!="prdkit.review.v3" then "receipt schema must be prdkit.review.v3"
            elif ([.id,.repo,.change,.reviewer,.from,.to,.head,.since,.base,.base_at,.verdict,.report] | all(.[];clean_string)|not) then "missing or mistyped receipt field"
            elif (.id|test("^[0-9a-f]{32}$")|not) or (.change|test("^[0-9]{3,}-[a-z0-9]+(-[a-z0-9]+)*$")|not) or
                (.reviewer|test("^[a-z0-9][a-z0-9_.-]*$")|not) then "invalid receipt id, change or reviewer"
            elif (.repo|ascii_downcase)!=($repo|ascii_downcase) or .pr!=$n then "receipt repo or pr does not match its posting PR"
            elif .reviewer=="owner" then "the owner approves natively, never with a receipt"
            elif (.from!="start" and (.from|fp|not)) or (.to!="none" and (.to|fp|not)) or
                (.head|hex40|not) or (.base_at|hex40|not) or (.since!="" and (.since|hex40|not)) or
                (.base|startswith("refs/remotes/origin/")|not) then "invalid receipt token forms"
            elif (.from=="start") != (.since=="") then "from and since disagree"
            elif (.verdict!="PASS" and .verdict!="FAIL") or ([.critical,.high,.medium,.low]|all(.[];nat)|not) then "invalid verdict or finding counts"
            elif .to=="none" and (blocking|not) then "none is only valid on a blocking verdict"
            elif has("restates") and ((.restates|type)!="string" or (.restates|test("^[1-9][0-9]*$")|not)) then "invalid restates review id"
            elif has("restates_pr") and (has("restates")|not) then "restates_pr requires restates"
            elif has("restates_pr") and ((.restates_pr|nat|not) or .restates_pr==0 or .restates_pr==$n) then "invalid restates_pr"
            else "" end;
        [ .[] as $s | $s.reviews[] | select(.state!="PENDING") | . as $r |
          (.body // "" | if type=="string" then . else "" end | payload) as $b |
          (($r.author.__typename // "") as $t | (if $t=="Bot" then "bot:" elif $t=="User" then "user:" else "?:" end)+($r.author.databaseId|tostring)) as $actor |
          ($publishers|split("\n")|index($actor)!=null) as $trusted |
          select(($s.pr.number==$current or ($s.pr.merged|not)) or $b.parsed.restates? != null) |
          {origin:$s.pr.number,review:($r.fullDatabaseId|tostring),time:$r.submittedAt,url:$r.url,
           merged:$s.pr.merged,raw_id:(if ($b.parsed|type)=="object" then $b.parsed.id else null end),payload:$b.parsed,trusted:$trusted,
            actor:$actor,ignored:($trusted|not),shaped:($b.starts>0),
           note:(if $trusted and $isolation=="shared" and $r.author.databaseId==$s.pr.author.databaseId then
               "receipts are authenticated to \($r.author.login), which also authored this PR: they bind content, order and counts, not the reviewer\u0027s independence" else "" end),
           error:(if $r.lastEditedAt!=null or $r.editor!=null then "edited receipt"
                  elif $b.starts!=1 or $b.ends!=1 or $b.inside then "expected exactly one receipt block"
                  elif $isolation=="required" and $r.author.databaseId==$s.pr.author.databaseId then "publisher also authored this PR (isolation required)"
                  else ($b.parsed|schema_error($s.pr.number)) end)} ] |
        sort_by(.time, (.review|length), .review) | to_entries[] | .value + {seq:(.key+1)}
        ' "$work/sources" > "$work/classified"; then RC_ERROR='could not normalize host reviews'; return 1; fi
    RC_IGNORED="$(jq -s '[.[]|select(.ignored and .shaped)]|length' "$work/classified")"
    : > "$work/validated"
    while IFS= read -r item; do
        [ "$(printf '%s' "$item" | jq -r .ignored)" = false ] || continue
        error="$(printf '%s' "$item" | jq -r .error)"
        if [ -z "$error" ]; then
            fields="$(printf '%s' "$item" | jq -r '.payload | [.change,.from,.to,.head,.since,.base,.base_at]|join("\u001f")')"
            IFS=$'\037' read -r change from to rhead since base base_at <<< "$fields"
            _receipts_consistency "$root" "$change" "$from" "$to" "$rhead" "$since" "$base" "$base_at" || error="$RC_ERROR"
        fi
        printf '%s' "$item" | jq -c --arg error "$error" '.error=$error' >> "$work/validated" || return 1
    done < "$work/classified"
    # Resolve repairs before extracting carry. A repair replaces, never deletes, an invalid row
    # and inherits its origin, sequence and timestamp; its transport fields do not grant scope.
    if ! jq -s --argjson current "$RC_PR" '
        . as $all |
        reduce (.[] | select(.error=="" and .payload.restates? != null)) as $r
          ($all;
           ($r.payload.restates_pr // $r.origin) as $origin |
           ([range(0;length) as $i | select(.[$i].origin==$origin and .[$i].review==$r.payload.restates) | $i][0]) as $i |
           if $i!=null and (.[$i].error!="" or (.[$i].repaired==true and .[$i].payload==($r.payload|del(.restates,.restates_pr)|.pr=$origin))) and .[$i].seq<$r.seq and
               .[$i].actor==$r.actor and (.[$i].raw_id==null or .[$i].raw_id==$r.payload.id) then
               .[$i] = (.[$i] + {error:"",repaired:true,payload:($r.payload|del(.restates,.restates_pr)|.pr=$origin),raw_id:$r.payload.id}) |
               map(if .seq==$r.seq then .consumed=true else . end)
            else map(if .seq==$r.seq then .error="restatement does not replace an earlier invalid receipt with the same id and publisher" else . end) end) |
        map(select(.consumed!=true)) |
        # Replays fix their first position. A conflicting id invalidates every occurrence.
        . as $resolved |
        map(. as $r | if .error=="" then
            ([$resolved[]|select(.error=="" and .payload.id==$r.payload.id)|.payload]|unique|length) as $variants |
            if $variants>1 then .error="same receipt id has different content"
            elif any($resolved[]; .error=="" and .payload==$r.payload and .seq<$r.seq) then .consumed=true else . end
            else . end) |
        map(select(.consumed!=true and (.origin==$current or (.merged|not))))
        ' "$work/validated" > "$work/resolved.json"; then RC_ERROR='could not resolve restatements'; return 1; fi
    : > "$RC_FILE"
    jq -r --argjson current "$RC_PR" '.[] |
        if .error!="" then ["X",.seq,.origin,.review,.error]
        else . as $r | .payload as $p |
            ["R",.seq,.origin,.review,.time,$p.id,$p.change,$p.reviewer,$p.from,$p.to,$p.head,$p.since,$p.base,$p.base_at,
             $p.verdict,$p.critical,$p.high,$p.medium,$p.low,$p.report,(if .origin==$current then 0 else 1 end)] end |
        map(tostring)|join("\u001f")' "$work/resolved.json" > "$RC_FILE" || return 1
    while IFS= read -r raw; do [ -z "$raw" ] || RC_NOTES+=("$raw"); done < <(jq -sr '[.[]|.note|select(.!="")]|unique[]' "$work/validated")
    [ "$RC_ISOLATION" != shared ] || RC_NOTES+=("Publisher isolation is shared: authentication does not establish the reviewer's independence.")
    RC_ERROR=""
}

review_receipts_write() { # destination; writer never changes RC_FILE
    local destination="$1" temp
    temp="$(mktemp "${destination}.XXXXXX")" || { RC_ERROR='cannot create snapshot'; return 1; }
    if ! {
        printf 'prdkit-receipts 1\037repo=%s\037pr=%s\037pr_head=%s\037pr_created=%s\037base=%s\037fetched=%s\037isolation=%s\037pr_author=%s\n' \
            "$RC_REPO" "$RC_PR" "$RC_PR_HEAD" "$RC_PR_CREATED" "$RC_BASE" "$RC_FETCHED" "$RC_ISOLATION" "$RC_PR_AUTHOR"
        cat "$RC_FILE"
    } > "$temp" || ! mv "$temp" "$destination"; then rm -f "$temp"; RC_ERROR='cannot write snapshot'; return 1; fi
}

review_receipts_read() { # snapshot work; no gh or jq, including on errors
    local file="$1" work="$2" header magic repo pr prhead created base fetched isolation author
    RC_ERROR=""; RC_IGNORED=0; RC_NOTES=(); RC_FILE="$work/receipts"
    if [ ! -f "$file" ] || ! LC_ALL=C awk -F '\037' '
        function digits(s) { return s ~ /^[0-9]+$/ }
        NR==1 { if (NF!=9 || $1!="prdkit-receipts 1") bad=1; next }
        $1=="R" { if (NF!=21 || !digits($2) || !digits($3) || !digits($4) || ($21!="0" && $21!="1") || $2<=last) bad=1; last=$2; next }
        $1=="X" { if (NF!=5 || !digits($2) || !digits($3) || !digits($4) || $5=="" || $2<=last) bad=1; last=$2; next }
        $1=="O" { if (NF!=6 || !digits($2) || $4 !~ /^(APPROVED|CHANGES_REQUESTED|DISMISSED)$/) bad=1; next }
        { bad=1 } END { exit (bad || NR==0) }' "$file"; then RC_ERROR='malformed receipt snapshot'; return 1; fi
    IFS= read -r header < "$file" || { RC_ERROR='empty receipt snapshot'; return 1; }
    IFS=$'\037' read -r magic repo pr prhead created base fetched isolation author <<< "$header"
    RC_ERROR='invalid snapshot header'
    case "$repo" in repo=?*/*) RC_REPO="${repo#repo=}" ;; *) RC_ERROR='invalid snapshot repo'; return 1 ;; esac
    case "$pr" in pr=*) RC_PR="${pr#pr=}" ;; *) return 1 ;; esac
    case "$prhead" in pr_head=*) RC_PR_HEAD="${prhead#pr_head=}" ;; *) return 1 ;; esac
    case "$created" in pr_created=*) RC_PR_CREATED="${created#pr_created=}" ;; *) return 1 ;; esac
    case "$base" in base=*) RC_BASE="${base#base=}" ;; *) return 1 ;; esac
    case "$fetched" in fetched=*) RC_FETCHED="${fetched#fetched=}" ;; *) return 1 ;; esac
    case "$isolation" in isolation=required|isolation=shared) RC_ISOLATION="${isolation#isolation=}" ;; *) return 1 ;; esac
    case "$author" in pr_author=*) RC_PR_AUTHOR="${author#pr_author=}" ;; *) return 1 ;; esac
    if ! [[ "$RC_PR" =~ ^[1-9][0-9]*$ && "$RC_PR_AUTHOR" =~ ^[1-9][0-9]*$ && "$RC_PR_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
        RC_ERROR='invalid snapshot PR metadata'; return 1
    fi
    mkdir -p "$work" && sed '1d' "$file" > "$RC_FILE" || return 1
    RC_ERROR=""
}

_receipts_row_valid() { # R row fields are local to the calling function (dynamic scope)
    [[ "$receipt_id" =~ ^[0-9a-f]{32}$ && "$rhead" =~ ^[0-9a-f]{40}$ && "$base_at" =~ ^[0-9a-f]{40}$ ]] || return 1
    is_change_id "$change" && [[ "$reviewer" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] && [ "$reviewer" != owner ] || return 1
    { [ "$from" = start ] || review_is_fp "$from"; } && { [ "$to" = none ] || review_is_fp "$to"; } || return 1
    [ "$since" = "" ] || [[ "$since" =~ ^[0-9a-f]{40}$ ]] || return 1
    if [ "$from" = start ]; then [ -z "$since" ] || return 1; else [ -n "$since" ] || return 1; fi
    case "$base" in refs/remotes/origin/?*) ;; *) return 1 ;; esac
    case "$verdict" in PASS|FAIL) ;; *) return 1 ;; esac
    [[ "$c" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ && "$l" =~ ^[0-9]+$ ]] || return 1
    [ "$to" != none ] || _receipts_blocking "$verdict" "$c" "$h" "$m" "$scope_rigor"
}
_receipts_blocking() { # verdict c h m rigor
    ! { [ "$1" = PASS ] && [ "$2" = 0 ] && [ "$3" = 0 ] && { [ "$5" = light ] || [ "$4" = 0 ]; }; }
}

review_receipts_scope() { # change rigor registry work root; local checks also run for snapshots
    local checked="$1" scope_rigor="$2" scope_registry="$3" work="$4" root="$5"
    local type seq origin review time receipt_id change reviewer from to rhead since base base_at verdict c h m l report carried reason row
    local n k j candidate clear block scope start_fp scoped
    local rs=() origins=() changes=() reviewers=() froms=() tos=() blocks=() seqs=() links=()
    RC_PROBLEMS=(); RC_COVERAGE="$work/coverage"; RC_INVALID=0; RC_CARRIED=0; RC_RECEIPTS=0
    : > "$RC_COVERAGE" || { RC_ERROR='cannot write receipt coverage'; return 1; }
    scoped="$(mktemp "$work/scoped.XXXXXX")" || { RC_ERROR='cannot allocate scoped receipts'; return 1; }
    while IFS= read -r row; do
        IFS=$'\037' read -r type seq origin review time receipt_id change reviewer from to rhead since base base_at verdict c h m l report carried <<< "$row"
        case "$type" in
            O) printf '%s\n' "$row" >> "$scoped"; continue ;;
            X)
                IFS=$'\037' read -r type seq origin review reason <<< "$row"
                RC_INVALID=$((RC_INVALID+1)); RC_PROBLEMS+=("receipt https://github.com/$RC_REPO/pull/$origin#pullrequestreview-$review: $reason")
                printf '%s\n' "$row" >> "$scoped"
                [ "$origin" = "$RC_PR" ] || RC_CARRIED=$((RC_CARRIED+1)); continue ;;
            R) RC_RECEIPTS=$((RC_RECEIPTS+1)) ;;
            *) RC_ERROR='invalid normalized receipt row'; return 1 ;;
        esac
        RC_ERROR="invalid receipt tokens or fields"
        if ! _receipts_row_valid || ! _receipts_consistency "$root" "$change" "$from" "$to" "$rhead" "$since" "$base" "$base_at"; then
            RC_INVALID=$((RC_INVALID+1)); RC_PROBLEMS+=("receipt https://github.com/$RC_REPO/pull/$origin#pullrequestreview-$review: $RC_ERROR")
            printf 'X\037%s\037%s\037%s\037%s\n' "$seq" "$origin" "$review" "$RC_ERROR" >> "$scoped"
            [ "$origin" = "$RC_PR" ] || RC_CARRIED=$((RC_CARRIED+1)); continue
        fi
        block=false; if _receipts_blocking "$verdict" "$c" "$h" "$m" "$scope_rigor"; then block=true; fi
        rs+=("$row"); origins+=("$origin"); changes+=("$change"); reviewers+=("$reviewer"); froms+=("$from"); tos+=("$to"); blocks+=("$block"); seqs+=("$seq")
        links+=("https://github.com/$RC_REPO/pull/$origin#pullrequestreview-$review")
    done < "$RC_FILE"
    # A closed source is evaluated in its own scope first. Only a still-standing blocker carries;
    # on this PR only a later full PASS for the origin or checked change can clear that carry.
    for k in ${rs[@]+"${!rs[@]}"}; do
        if ${blocks[k]}; then
            clear=false
            for j in ${rs[@]+"${!rs[@]}"}; do
                [ "${reviewers[j]}" = "${reviewers[k]}" ] && ! ${blocks[j]} && [ "${seqs[j]}" -gt "${seqs[k]}" ] || continue
                [ "$(review_eligibility "$scope_registry" "${reviewers[j]}")" = reviewer ] || continue
                [ "${tos[j]}" != none ] && [ "${tos[j]}" != "$REVIEW_FP_EMPTY" ] && [ "${froms[j]}" != "${tos[j]}" ] || continue
                if [ "${origins[j]}" = "${origins[k]}" ]; then
                    if [ "${froms[j]}" = start ] && { [ "${changes[j]}" = "${changes[k]}" ] || { [ "${origins[k]}" = "$RC_PR" ] && [ "${changes[j]}" = "$checked" ]; }; }; then
                        clear=true; break
                    fi
                    [ "${changes[j]}" = "${changes[k]}" ] || continue
                    # Reachability stays inside the blocker's own change and origin PR. A full
                    # PASS for the checked change can clear, but never grants a foreign edge.
                    start_fp="${tos[k]}"; [ "$start_fp" != none ] || continue
                    scope="$start_fp"; n=0
                    while [ "$n" -lt "${#rs[@]}" ]; do
                        for candidate in ${rs[@]+"${!rs[@]}"}; do
                            [ "$candidate" != "$j" ] && [ "${origins[candidate]}" = "${origins[k]}" ] &&
                                [ "${changes[candidate]}" = "${changes[k]}" ] && [ "${reviewers[candidate]}" = "${reviewers[k]}" ] &&
                                [ "${seqs[candidate]}" -gt "${seqs[k]}" ] && [ "${tos[candidate]}" != none ] || continue
                            case $'\n'"$scope"$'\n' in *$'\n'"${froms[candidate]}"$'\n'*) scope="$scope"$'\n'"${tos[candidate]}" ;; esac
                        done
                        case $'\n'"$scope"$'\n' in *$'\n'"${froms[j]}"$'\n'*) clear=true; break ;; esac
                        n=$((n+1))
                    done
                    $clear && break
                elif [ "${origins[j]}" = "$RC_PR" ] && [ "${froms[j]}" = start ] &&
                    { [ "${changes[j]}" = "${changes[k]}" ] || [ "${changes[j]}" = "$checked" ]; }; then
                    clear=true; break
                fi
            done
            if ! $clear; then
                RC_PROBLEMS+=("receipt ${links[k]}: ${reviewers[k]} ${changes[k]} blocking verdict stands: no later clean PASS in scope")
                [ "${origins[k]}" = "$RC_PR" ] || RC_CARRIED=$((RC_CARRIED+1))
                [ "${origins[k]}" = "$RC_PR" ] || printf '%s\n' "${rs[k]}" >> "$scoped"
            fi
        fi
        [ "${origins[k]}" != "$RC_PR" ] || printf '%s\n' "${rs[k]}" >> "$scoped"
        if [ "${origins[k]}" = "$RC_PR" ] && [ "${changes[k]}" = "$checked" ]; then printf '%s\n' "${rs[k]}" >> "$RC_COVERAGE"; fi
    done
    # X rows were collected separately; retain the immutable host sequence across both kinds.
    if ! LC_ALL=C sort -t $'\037' -k2,2n "$scoped" > "$work/scoped-sorted" || ! mv "$work/scoped-sorted" "$scoped"; then
        RC_ERROR='cannot order scoped receipts'; return 1
    fi
    RC_FILE="$scoped"
    RC_RECEIPTS="$(awk -F '\037' '$1=="R" { n++ } END { print n+0 }' "$RC_FILE")"
    RC_ERROR=""
}
