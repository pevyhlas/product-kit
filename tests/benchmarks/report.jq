# Normalized v1 contract. Invalid input produces no report, including invalid later runs.
def require($ok; $why): if $ok then . else error($why) end;
def text: type == "string" and length > 0;
def count: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
def amount: type == "number" and . >= 0 and . < 1e100;
def maybe_count: . == null or count;
def unique_values: length == (unique | length);
def token_keys: ["uncached_input", "cache_read", "cache_write", "output", "reasoning"];
def tokens_known: .tokens | all(token_keys[] as $k | .[$k]; . != null);
def messages: [.attempts[].messages[]];
def usage_complete: all(.attempts[]; (.usage_status == "complete" or .usage_status == "none") and all(.messages[]; tokens_known));
def cost_complete: all(.attempts[]; (.usage_status == "complete" or .usage_status == "none") and all(.messages[]; .cost.amount != null));

require(type == "object"; "study must be an object") |
require(.schema_version == 1; "unsupported schema_version") |
require(.kind == "fixture" or .kind == "observed"; "kind must distinguish fixture from observed") |
require(.study_id | text; "study_id required") |
require(.phase == "adoption" or .phase == "steady-state"; "separate adoption from steady-state") |
require(all([.task_set_revision, .acceptance_policy, .permissions, .review_policy, .environment, .currency][]; text); "frozen study contracts required") |
require((.tasks | type == "array" and length > 0 and unique_values and all(.[]; text)) and (.repetitions | count and . > 0); "tasks and positive repetitions required") |
require(.arms | type == "array" and length > 0; "arms required") |
require([.arms[].id] | unique_values; "duplicate arm") |
require(all(.arms[]; all([.id,.kit_revision,.harness,.harness_version,.model,.instructions_digest][]; text)); "every arm needs frozen kit/harness/model/instructions provenance") |
require(.runs | type == "array"; "runs must be an array") |
. as $study |
require(all(.runs[]; (.arm as $id | any($study.arms[]; .id == $id)) and (.task as $id | $study.tasks | index($id) != null) and (.replicate | count and . > 0 and . <= $study.repetitions)); "unknown arm/task or invalid replicate") |
require([.runs[] | [.arm,.task,.replicate]] | unique_values; "duplicate task replicate: retries belong in attempts") |
require(all(.runs[]; .outcome == "accepted" or .outcome == "failed" or .outcome == "abandoned" or .outcome == "error"); "invalid outcome") |
require(all(.runs[]; (.attempts | type == "array" and length > 0) and (.final_revision | text)); "runs require attempts and final revision") |
require(all(.runs[].attempts[]; all([.id,.agent,.session,.role,.transcript][]; text) and (.elapsed_s | count) and (.messages | type == "array")); "attempt identity, transcript, elapsed time and messages required") |
require(all(.runs[]; [.attempts[].id] | unique_values); "duplicate attempt id") |
require(all(.runs[].attempts[];
    (.usage_status == "complete" and (.messages | length > 0)) or
    (.usage_status == "none" and (.messages | length == 0)) or
    .usage_status == "partial" or .usage_status == "unknown"); "usage_status must explicitly classify coverage") |
require(all(.runs[].attempts[].messages[];
    (.meter_id | text) and (.evidence | text) and (.tokens | type == "object") and
    (.tokens | keys == (token_keys | sort)) and (.tokens | all(.[]; maybe_count)) and
    (.cost | type == "object") and
    (if .cost.amount == null then .cost.basis == "unknown"
     else (.cost.amount | amount) and (.cost.basis == "billed" or .cost.basis == "estimated" or .cost.basis == "subscription-allocated") and (.cost.reference | text) end)); "invalid usage counters/cost basis/evidence") |
require([.runs[].attempts[].messages[].meter_id] | unique_values; "duplicate meter_id would double-count replayed usage") |
require(all(.runs[]; if .outcome == "accepted" then
    . as $run | (.acceptance | type == "object") and .acceptance.result == "pass" and
    .acceptance.revision == .final_revision and (.acceptance.reviewer | text) and
    (.acceptance.checks_evidence | text) and (.acceptance.review_evidence | text) and
    any(.attempts[]; .role == "reviewer" and .agent == $run.acceptance.reviewer) and
    any(.attempts[]; .role != "reviewer") and
    all(.attempts[]; if .role != "reviewer" then .agent != $run.acceptance.reviewer else true end) and
    ([.attempts[]|select(.role == "reviewer" and .agent == $run.acceptance.reviewer)|.session] as $review_sessions |
     all(.attempts[]|select(.role != "reviewer"); .session as $s | $review_sessions | index($s) == null))
    else .acceptance == null end); "accepted outcome needs exact-revision independent review and checks; other outcomes have null acceptance") |

# Every failed/abandoned/error run and every worker/reviewer/resume attempt is included.
def summarize($runs):
    [$runs[].attempts[].messages[]] as $m |
    [$runs[].attempts[]] as $a |
    ([$runs[] | select(.outcome == "accepted")] | length) as $accepted |
    ($runs | length > 0 and all(.[]; usage_complete)) as $uc |
    ($runs | length > 0 and all(.[]; cost_complete)) as $cc |
    ([$m[] | .cost.amount // 0] | add // 0) as $observed_cost |
    (reduce token_keys[] as $k ({}; .[$k] = ([$m[] | .tokens[$k] // 0] | add // 0))) as $tokens |
    ($tokens | [.[]] | add) as $observed_tokens |
    {
      changes: ($runs|length), accepted: $accepted,
      failed: ([$runs[]|select(.outcome=="failed")]|length),
      abandoned: ([$runs[]|select(.outcome=="abandoned")]|length),
      errors: ([$runs[]|select(.outcome=="error")]|length),
      attempts: ($a|length), messages: ($m|length),
      declared_complete_attempts: ([$a[]|select(.usage_status=="complete" or .usage_status=="none")]|length),
      usage_complete: $uc, cost_complete: $cc,
      observed_tokens: $tokens, observed_cost: $observed_cost,
      cost_bases: ([$m[]|select(.cost.amount!=null)|.cost.basis]|unique),
      cost_by_basis: (reduce ["billed","estimated","subscription-allocated"][] as $b ({}; .[$b] = ([$m[]|select(.cost.basis==$b)|.cost.amount]|add//0))),
      total_tokens: (if $uc then $observed_tokens else null end),
      total_cost: (if $cc then $observed_cost else null end),
      tokens_per_accepted_change: (if $uc and $accepted>0 then $observed_tokens/$accepted else null end),
      cost_per_accepted_change: (if $cc and $accepted>0 then $observed_cost/$accepted else null end),
      summed_attempt_seconds: ([$a[].elapsed_s]|add//0),
      roles: ([$a[].role]|unique|map(. as $role | {role:$role, attempts:([$a[]|select(.role==$role)]|length), observed_cost:([$a[]|select(.role==$role)|.messages[]|.cost.amount//0]|add//0)}))
    };
{
 schema_version:1, study_id:.study_id, kind:.kind, phase:.phase, currency:.currency,
 contracts:{task_set_revision:.task_set_revision, acceptance_policy:.acceptance_policy, review_policy:.review_policy, permissions:.permissions, environment:.environment},
 matrix_complete: ((.runs|length) == ((.arms|length)*(.tasks|length)*.repetitions)),
 harness_model_matched: ([.arms[]|[.harness,.harness_version,.model]]|unique|length==1),
 evidence_limit:"Recorded identities/evidence are trusted inputs, not proof of independent judgment or complete capture. No superiority claim or automatic ranking.",
 arms:[.arms[] | . as $arm | {provenance:$arm, metrics:summarize([$study.runs[]|select(.arm==$arm.id)])}]
}
