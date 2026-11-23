#!/usr/bin/env bash
# Optional advisory scheduling from the native gate's own diagnostic facts.
# No receipt validator, hypothetical verdicts, publication or network calls of its own.
# shellcheck disable=SC2154,SC2034,SC2016 # Builder globals; jq programs use literal variables.

review_plan_prepare() {
    GATE_STATUS=""; GATE_VALID=false; GATE_REASON="no --pr supplied"; PLAN_VALID=false; PLAN_REASON="no advisory scope map"
    if [ -n "$PR_URL" ]; then
        GATE_STATUS=0
        bash "$SCRIPT_DIR/check-review.sh" --json --diagnostics --repo "$REPO_ROOT" --head "$HEAD_SHA" \
            --base "${FP_REF:-origin/HEAD}" --pr "$PR_URL" "$CHANGE_ID" \
            > "$PACKAGE_SCRATCH/gate.json" 2> "$PACKAGE_SCRATCH/gate.stderr" || GATE_STATUS=$?
        printf '%s\n' "$GATE_STATUS" > "$PACKAGE_SCRATCH/gate.status"
        GATE_REASON="native evaluation unavailable/malformed, or host/content/policy binding incomplete"
        if command -v jq >/dev/null 2>&1 && jq -e --arg change "$CHANGE_ID" --arg head "$HEAD_SHA" \
            --arg base "$FP_REF" --arg at "$FP_BASE_AT" --arg policy "$POLICY_AT" --arg fp "$FINGERPRINT" --arg pr "$PR_URL" '
            def string: type=="string";
            def boolean: type=="boolean";
            .change==$change and .head==$head and .pr==$pr and .base_trusted and
            (.result=="pass" or .result=="fail") and (.problems|type)=="array" and
            .fingerprint==$fp and $fp!="" and .authority=="host" and
            (.diagnostics as $d | $d.head==$head and $d.base_ref==$base and $d.base_at==$at and
             $d.policy_at==$policy and $d.receipt_ready and $d.host_content_bound and
             ($d.latest|type)=="array" and all($d.latest[];
                  ([.reviewer,.eligibility,.receipt,.from,.to,.provenance]|all(.[];string)) and
                 ([.clean,.end_covered,.standing]|all(.[];boolean))) and
             ($d.edges|type)=="array" and all($d.edges[]; (.from|string) and (.to|string)) and
             ($d.standing|type)=="array" and all($d.standing[];
                 [.reviewer,.to,.receipt]|all(.[];string)) and
             ($d.registry|type)=="array" and all($d.registry[]; [.reviewer,.eligibility]|all(.[];string)) and
             ($d.scope_blockers|type)=="array" and all($d.scope_blockers[];
                  ([.reviewer,.change,.origin_pr,.to,.receipt]|all(.[];string)) and (.full_required|boolean)) and
             ($d.references|type)=="array" and all($d.references[];string) and
             ($d.current_reviewers|type)=="array" and all($d.current_reviewers[];string) and
             ($d.problem_classes|type)=="array" and all($d.problem_classes[];string) and
             ($d.problem_classes|length)==(.problems|length))' "$PACKAGE_SCRATCH/gate.json" >/dev/null 2>&1 &&
            { [ "$GATE_STATUS" = 0 ] || [ "$GATE_STATUS" = 1 ]; }; then GATE_VALID=true; fi
        if ! $GATE_VALID && command -v jq >/dev/null 2>&1; then
            GATE_REASON="$(jq -r --arg expected "$HEAD_SHA" --arg base "$FP_BASE_AT" --arg policy "$POLICY_AT" '
                "authority=\(.authority // "unknown"); receipt_ready=\(.diagnostics.receipt_ready // false); " +
                "host_content_bound=\(.diagnostics.host_content_bound // false); " +
                "head_matches=\(.head==$expected); base_tip_matches=\(.diagnostics.base_at==$base); " +
                "policy_matches=\(.policy_at==$policy); native problems: \((.problems // [])|join("; "))"
                ' "$PACKAGE_SCRATCH/gate.json" 2>/dev/null || printf '%s' "$GATE_REASON")"
        fi
    fi
    if [ -n "$REVIEW_PLAN" ]; then
        local before after
        before="$(git -C "$REPO_ROOT" hash-object --no-filters "$REPO_ROOT/$REVIEW_PLAN")"
        cp "$REPO_ROOT/$REVIEW_PLAN" "$PACKAGE_SCRATCH/plan.json"
        after="$(git -C "$REPO_ROOT" hash-object --no-filters "$REPO_ROOT/$REVIEW_PLAN")"
        [ "$before" = "$after" ] && [ "$before" = "$(git -C "$REPO_ROOT" hash-object --no-filters "$PACKAGE_SCRATCH/plan.json")" ] ||
            { echo "ERROR: review plan changed while copying" >&2; exit 1; }
        if ! review_file_without_nul "$PACKAGE_SCRATCH/plan.json" ||
        ! jq -se --arg change "$CHANGE_ID" --arg head "$HEAD_SHA" --arg since "$SINCE" --arg base "$FP_REF" \
            --arg at "$FP_BASE_AT" --arg policy "$POLICY_AT" --arg pr "$PR_URL" '
            def text: type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not);
            def strings: type=="array" and length>0 and all(.[];text) and (unique|length)==length;
            length==1 and (.[0]|type)=="object" and (.[0] |
            .change==$change and .head==$head and .since==$since and .base_ref==$base and
            .base_at==$at and .policy_at==$policy and .pr==$pr and
            (.reviewers|type)=="array" and (.reviewers|length)>0 and
            ([.reviewers[].id]|unique|length)==(.reviewers|length) and
            all(.reviewers[]; (.id|text) and (.action=="review" or .action=="unaffected") and
                (.reason|text) and (.obligations|strings) and (.references|strings)) and
            (.fixes|type)=="array" and (.fixes|length)>0 and
            ([.fixes[].path]|unique|length)==(.fixes|length) and
            all(.fixes[]; (.path|text) and (.reviewers|strings) and (.obligations|strings) and
                (.receipt|text) and (.finding|text)) and
            ((.context // [])|type)=="array" and all((.context // [])[];
                (.path|text) and (.selector|text) and (.reason|text)) and
            ((.context // [])|unique_by([.path,.selector])|length)==((.context // [])|length))' "$PACKAGE_SCRATCH/plan.json" >/dev/null; then
            echo "ERROR: invalid/stale advisory plan binding or incomplete fields; no round allocated" >&2; exit 1
        fi
        local p
        while IFS= read -r p; do
            safe_path "$p" || { echo "ERROR: unsafe plan path: $p" >&2; exit 1; }
        done < <(jq -r '.fixes[].path, (.context // [])[].path' "$PACKAGE_SCRATCH/plan.json")
        PLAN_VALID=true; PLAN_REASON="advisory lead judgment only; not a verdict"
    fi
    # Refs must still name the frozen tips after the one native collection.
    [ -n "$PR_URL" ] || return 0
    if { [ -n "$FP_REF" ] && [ "$(git -C "$REPO_ROOT" rev-parse "$FP_REF^{commit}")" != "$FP_BASE_AT" ]; } ||
        { [ -n "$POLICY_REF" ] && [ "$(git -C "$REPO_ROOT" rev-parse "$POLICY_REF^{commit}")" != "$POLICY_AT" ]; }; then
        echo "ERROR: policy/integration binding changed during collection; no round allocated" >&2; exit 1
    fi
}

review_plan_write() {
    local file p selector reason targets=() candidate row reviewer from to
    for file in gate.json gate.status gate.stderr; do
        [ -f "$PACKAGE_SCRATCH/$file" ] || continue
        cp "$PACKAGE_SCRATCH/$file" "$PACKAGE_DIR/$file"; inventory "$file" "fresh check-review.sh evaluation (not a replay authority)"
    done
    if $PLAN_VALID; then
        cp "$PACKAGE_SCRATCH/plan.json" "$PACKAGE_DIR/review-plan.json"
        inventory review-plan.json "caller-supplied advisory scope judgment"
        while IFS=$'\037' read -r p selector reason; do
            context_select "$HEAD_SHA" "$p" "$selector" explicit-plan "$reason"
        done < <(jq -r '(.context // [])[] | [.path,.selector,.reason]|join("\u001f")' "$PACKAGE_DIR/review-plan.json")
        : > "$PACKAGE_SCRATCH/obligation-gaps"
        while IFS= read -r p; do
            before="$(wc -l < "$PACKAGE_DIR/context-gaps.txt")"
            case "$p" in
                *'#'*)
                    file="${p%%#*}"; selector="${p#*#}"
                    reason="$HEAD_SHA"; case "$file" in .prdkit/memory/*) reason="$POLICY_AT" ;; esac
                    context_select "$reason" "$file" "$selector" plan-obligation "explicit advisory obligation" ;;
                *) context_id "$p" "advisory obligation reference" ;;
            esac
            [ "$before" = "$(wc -l < "$PACKAGE_DIR/context-gaps.txt")" ] || printf '%s\n' "$p" >> "$PACKAGE_SCRATCH/obligation-gaps"
        done < <(jq -r '[.reviewers[].obligations[], .fixes[].obligations[]]|unique[]' "$PACKAGE_DIR/review-plan.json")
    fi
    [ -f "$PACKAGE_SCRATCH/obligation-gaps" ] || : > "$PACKAGE_SCRATCH/obligation-gaps"
    if ! $GATE_VALID; then
        printf '{"coverage":"unknown","dispatch":"pending","reason":"%s","retained":null,"review_now":null,"prospective_carry":null,"scope_pending":["host evidence unavailable or unbound; no reduced-panel recommendation"]}\n' "$(json_escape "$GATE_REASON")" > "$PACKAGE_DIR/dispatch.json"
        inventory dispatch.json "unknown coverage; no verdict authority"; return
    fi
    # Compute structural accounting independently of prose. Canonical stream differences include
    # changed merge/base context; focused patch paths include metadata. Fallback additionally
    # requires every full-diff entry, including omitted merge resolutions, to be mapped.
    : > "$PACKAGE_SCRATCH/paths"
    if [ -n "$SINCE" ]; then
        review_delta_stream "$REPO_ROOT" "$CHANGE_ID" "$FP_BASE_AT" "$SINCE" > "$PACKAGE_SCRATCH/since.stream"
        review_delta_stream "$REPO_ROOT" "$CHANGE_ID" "$FP_BASE_AT" "$HEAD_SHA" > "$PACKAGE_SCRATCH/head.stream"
        review_stream_paths "$PACKAGE_SCRATCH/since.stream" "$PACKAGE_SCRATCH/head.stream" >> "$PACKAGE_SCRATCH/paths"
        if [ -n "${delta_from:-}" ]; then
            git -C "$REPO_ROOT" -c core.quotepath=true diff --ignore-submodules=none --name-only --no-renames "$delta_from" "$HEAD_SHA" >> "$PACKAGE_SCRATCH/paths"
        else git -C "$REPO_ROOT" -c core.quotepath=true diff --ignore-submodules=none --name-only --no-renames "$BASE_SHA" "$HEAD_SHA" >> "$PACKAGE_SCRATCH/paths"; fi
    fi
    LC_ALL=C sort -u "$PACKAGE_SCRATCH/paths" > "$PACKAGE_DIR/delta-paths.txt"
    inventory delta-paths.txt "complete conservative whole-entry accounting (fallback includes full diff)"
    # Reachability is EXACTLY the gate's helper, over its actual accepted edges only.
    source "$SCRIPT_DIR/review-coverage-lib.sh"
    g_from=(); g_to=()
    while IFS=$'\037' read -r from to; do g_from+=("$from"); g_to+=("$to"); done \
        < <(jq -r '.diagnostics.edges[] | [.from,.to]|join("\u001f")' "$PACKAGE_DIR/gate.json")
    : > "$PACKAGE_SCRATCH/reaches-since"
    if [ -n "$SINCE_FINGERPRINT" ]; then
        if leads_to "$REVIEW_FP_EMPTY" "$SINCE_FINGERPRINT"; then printf '%s\n' start >> "$PACKAGE_SCRATCH/reaches-since"; fi
        while IFS=$'\037' read -r reviewer to; do
            [ "$to" != start ] || to="$REVIEW_FP_EMPTY"
            if leads_to "$to" "$SINCE_FINGERPRINT"; then printf '%s\n' "$reviewer" >> "$PACKAGE_SCRATCH/reaches-since"; fi
        done < <(jq -r '.diagnostics.latest[] | [.reviewer,.to]|join("\u001f")' "$PACKAGE_DIR/gate.json")
    fi
    [ -f "$PACKAGE_DIR/review-plan.json" ] || printf '{"reviewers":[],"fixes":[]}\n' > "$PACKAGE_SCRATCH/plan.json"
    # No invented edge enters the graph. This JSON is scheduling advice alongside the unchanged
    # failing gate, and explicitly retains all native/foreign/carried/invalid/owner problems.
    jq -n --slurpfile gate "$PACKAGE_DIR/gate.json" --slurpfile plan "$PACKAGE_SCRATCH/plan.json" \
        --rawfile paths "$PACKAGE_DIR/delta-paths.txt" --rawfile reaches "$PACKAGE_SCRATCH/reaches-since" \
        --rawfile obligation_gaps "$PACKAGE_SCRATCH/obligation-gaps" \
        --rawfile gaps "$PACKAGE_DIR/context-gaps.txt" --arg since "$SINCE_FINGERPRINT" --arg empty "$REVIEW_FP_EMPTY" \
        --argjson mapped "$PLAN_VALID" --arg status "$GATE_STATUS" '
        $gate[0] as $g | $g.diagnostics as $d | $plan[0] as $p |
        ($paths|split("\n")|map(select(.!=""))) as $paths |
        ([$paths[]|select(startswith("\""))]) as $unsupported_paths |
        ($reaches|split("\n")) as $reaches |
        def eligible($id): any($d.registry[]; .reviewer==$id and .eligibility=="reviewer");
        def ref($r): $r=="new-change" or ($d.references|index($r)!=null);
        ([ $p.reviewers[] | select(.action=="review" and eligible(.id)) | .id ]) as $affected |
        ([ $d.standing[].reviewer, $d.scope_blockers[].reviewer,
            ($d.latest[]|select(.provenance!="verified")|.reviewer),
            (if ($d.problem_classes|index("record-format"))!=null then $d.latest[].reviewer else empty end)
          ] | unique) as $blockers |
        ([ $d.latest[] | . as $r | select(.eligibility=="reviewer" and .clean and .end_covered and
            (.standing|not) and ($blockers|index($r.reviewer)|not)) ]) as $retained |
        ([ $p.reviewers[].id ]) as $ids |
        ([ $d.current_reviewers[], $d.latest[].reviewer, $blockers[] ] | unique) as $prior |
        ([$prior[] | select(. as $id | $ids|index($id)|not)]) as $missing |
        ([$p.reviewers[] | select(eligible(.id)|not) | .id]) as $ineligible |
        ([$p.reviewers[] | . as $r | select(.action=="unaffected" and
            (any($d.latest[]; .reviewer==$r.id)|not)) | .id]) as $missing_initial |
        ([$paths[] | select(. as $path | any($p.fixes[]; .path==$path)|not)]) as $unmapped |
        ([$p.reviewers[].references[], $p.fixes[].receipt | select(ref(.)|not)]) as $badrefs |
        ([$p.fixes[] | select((.path as $path | $paths|index($path))==null or
            any(.reviewers[]; . as $id | $affected|index($id)|not)) | .path]) as $badfix |
        ([$p.fixes[] | . as $fix | select(any(.reviewers[];
            . as $id | any($p.reviewers[]; .id==$id and
                all($fix.obligations[]; . as $o | . != "" and ($p.reviewers[]|select(.id==$id)|.obligations|index($o))!=null))|not)) | .path]) as $badobligations |
        ($mapped and ($missing|length)==0 and ($ineligible|length)==0 and ($unmapped|length)==0 and
            ($badrefs|length)==0 and ($badfix|length)==0 and ($badobligations|length)==0 and
            ($missing_initial|length)==0 and ($unsupported_paths|length)==0 and
            $obligation_gaps=="" and ($paths|length)>0) as $scope |
        # A delta reviewer must own EVERY entry and have only standing blockers anchored at X.
        ([ $affected[] | . as $id | select(
            all($p.fixes[]; .reviewers|index($id)!=null) and
            all($d.scope_blockers[] | select(.reviewer==$id); (.full_required|not) and .to==$since) and
            all($d.latest[] | select(.reviewer==$id); .provenance=="verified") and
            all($d.standing[] | select(.reviewer==$id); .to==$since)) ]) as $delta_reviewers |
        ([ $d.latest[] | . as $r | select($scope and $since!="" and
            .eligibility=="reviewer" and .clean and (.standing|not) and (.end_covered|not) and
            ($blockers|index($r.reviewer)|not) and
            ($reaches|index("start"))!=null and ($reaches|index($r.reviewer))!=null and
            any($p.reviewers[]; .id==$r.reviewer and .action=="unaffected") and
            ($delta_reviewers|length)>0) |
            . + {pending_reviewers:$delta_reviewers,
                condition:"pending actual clean native since-to-head receipt(s), then fresh online gate evaluation"} ]) as $prospective |
        {coverage:"host",dispatch:"pending",gate_result:$g.result,gate_exit:($status|tonumber),
         retained:$retained, review_now:([$blockers[], $missing_initial[], (if $scope then $affected[] else empty end)]|unique),
         prospective_carry:$prospective,scope_valid:$scope,
         scope_pending:{missing_reviewers:$missing,ineligible:$ineligible,unmapped_delta:$unmapped,
             invalid_references:$badrefs,invalid_assignments:$badfix,unmapped_obligations:$badobligations,
             unsupported_paths:$unsupported_paths,
             missing_initial:$missing_initial,unresolved_obligations:($obligation_gaps|split("\n")|map(select(.!=""))),
             map_required:($mapped|not),context_gaps:($gaps|split("\n")|map(select(.!="")))},
         uncovered:[$d.latest[] | select(.end_covered|not) | .reviewer],
         blockers:{native:$d.standing,scope:$d.scope_blockers,
             invalid_receipts:$g.invalid_receipts,carried:$g.carried_blockers,owner:$g.owner,
             problem_classes:$d.problem_classes,problems:$g.problems},
         advisory:"lead judgment is not a verdict; retained coverage is not whole-gate approval; unresolved obligations need action"}' \
        > "$PACKAGE_DIR/dispatch.json"
    inventory dispatch.json "native facts and conditional advisory scheduling; never a verdict"
}
