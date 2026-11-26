#!/usr/bin/env bash
# Literal fill-in slots from the shipped templates, scoped to their project-owned destinations.
# Do not scan the templates themselves: they are editable and meant to contain placeholders.
# Keep this inventory in sync with the matching templates. Short tokens carry surrounding
# field syntax where needed; brackets in lists, diagrams and links are not fill-in slots.

template_residue_rows() ( # root, followed by the already discovered spec and change paths
    cd "$1" || return 1
    shift
    local path files=()
    for path in .prdkit/memory/constitution.md .prdkit/memory/agents.md .prdkit/memory/config.md \
                .prdkit/history/archive.md .prdkit/agents/*.md specs/inbox.md specs/records.md specs/authority.md "$@"; do
        [ ! -f "$path" ] || files+=("$path")
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    # shellcheck disable=SC2016 # awk uses its own $0
    LC_ALL=C awk -v marker="$PRDKIT_UNCONFIRMED_DEFAULT" "$SPEC_METADATA_SKIP_AWK"'
        function slots(group, text,   i, n, a) {
            n = split(text, a, "\037")
            for (i = 1; i <= n; i++) literal[group, ++count[group]] = a[i]
        }
        BEGIN {
            slots("constitution", "# <Project> constitution\037**Name**: <project>\037<human who owns outcomes and consequential choices>")
            slots("constitution", "<Commit, branch push, PR, merge, release, deploy and spending, each stated separately, with who may grant each. Standing owner policy is authority; missing authority is not permission. A limit that must hold, such as a spending ceiling, is a C- in specs/product/constraints.md; link it here.>")
            slots("constitution", "<Extra review for named risks (security, data migration, payments), checks required before merge, live checks per environment, and how an exception is asked for.>\037<A few testable rules. One that acts as a constraint gives its why, scope, source and revisit when.>")
            commands = "<Actual build, test and verification commands and their working directories>"
            slots("constitution", commands)
            slots("commands", commands)
            slots("agents", "| Intent owner | <human> |\037| Implementation | <session or worker> |\037| Independent review | <reviewer context> |")
            slots("agents", "tiers.json@<commit written by --refresh-baseline>\037<exact ids never to project, comma-separated; optional>\037<projection names kept without a definition, comma-separated; optional>")
            slots("agents", "<tier used by a definition>\037<verydeep, deep, standard or light>\037<tier:NAME or agent:NAME>\037<claude, opencode or *>\037<exact id or blank>\037<variant or blank>\037<why it deviates>")
            slots("config", "<numeric account id>\037<numeric owner id>")
            slots("agent-definition", "<Agent title>\037<What this agent is responsible for, and where that ends.>\037<What it reads, in what order, and what it must not do. A reviewer reads the package, the change record and the spec sections it is given by name, and only searches a readable `specs/` for the touched IDs and terms.>\037<The exact shape of what it returns.>")
            slots("agent-frontmatter", "name: agent-name\037domain: Domain / Role\037description: One line — when this agent should be dispatched.")
            slots("archive", "# <Product> — archive\037<Date — what happened and why it mattered; details at a Git commit and path.>")
            slots("inbox", "*YYYY-MM-DD · \037**Related**: <canonical spec/change links>\037<What needs the owner and why; concise context with links.>")
            slots("records", "HOLD <id>\037WAIVER <id>\037ATTEST <id>\037DEPLOY <app>\037owner=<role>\037scope=<part|env|change>\037since=<date>\037until=<date|condition>")
            slots("records", "check=<acceptance item>\037scope=<scope>\037expires=<date>\037by=<owner|agent>\037what=<claim>\037env=<env>\037version=<rev>\037date=<date>\037rev=<commit>\037by=<workflow run link>")
            slots("record-reason", "<reason>\037<evidence link>\037<why nothing is deployed there>")
            slots("authority", "**Source**: <durable source>\037**Date**: <YYYY-MM-DD>")
            slots("change", "# Change: <short name>\037**Opened**: <date>\037**Parts**: <P-ids>\037**Journeys**: <J-ids>\037**Tier**: <T0–T3>\037<Why now, for whom?>\037<C-01>: holds:\037holds: <how>\037| <ID> |\037<test, CI job, live run or owner trial>\037**Next**: <next action>")
            slots("spec", "# <Product> — spec\037**Last owner review**: <date>\037<journey>**\037<who> wants\037wants <intent>\037in <situation>;\037success is <result>")
            slots("product", "# <Product>\037<One sentence: what it is, for whom, and what changes for them.>\037**Stage**: <now>\037next: <stage>\037<One sentence: who struggles with what today.>")
            slots("product", "<what goes wrong, from their side>\037<assumed, desk research, observed or measured; a link>\037<a real target user>\037<their goal>\037<where, when, what limits them>\037| <surfaces> |")
            slots("product", "<whoever tests, deploys or hosts it, each with where it belongs: a constraint, Operations or a requirement>\037<journey>](product/journeys/\037<slug>.md)\037| <area> |\037| <Now stage> (now)\037| <Next stage> |\037| <Later stage> |")
            slots("product", "<Five to seven of the most important items in a line each, with their IDs.>\037<The thesis, and the signal that would prove it wrong.>")
            slots("product-diagram", "([<persona>])\037>|<surface>|\037<journey>]")
            slots("architecture", "# <Product> — architecture\037<platform document (`org/repo`, path) and the rules used>\037<One sentence: the shape of the system and why it fits the core loop.>\037<A few lines: where data lives and where the trust boundaries are.>")
            slots("architecture", "| P1 <name> |\037<runs or ships where>\037| <components> |\037p1-<slug>\037**<title>** (D-\037<the choice, in a line>")
            slots("architecture", "<trust boundaries, identity, encryption, personal data>\037<what is watched, who is alerted, how incidents run>\037<what is stored where, kept how long>\037<which part owns which interface; external systems>\037<each environment, what it is for, where it is provisioned>\037<delivery, tooling>")
            slots("architecture", "<The riskiest assumption and what breaks if it is wrong, in a line: [why it works](architecture/why-it-works.md).>\037<L1 decisions intentionally not made; agents choose them without asking.>")
            slots("architecture-diagram", "([<persona>])\037 as <persona>\037<part>]\037>|<what flows>|\037[(<external system>)]\037: <action>\037: <request>\037: <result>")
            slots("topic", "# <Product> — <topic>\037- **Trust boundaries**: <where they are, and what crosses each>\037<who signs in how; which roles see what>\037<in transit, at rest, who holds keys; what it does not protect>\037<categories, legal basis, rights, cited C- and R-; detail in data.md>")
            slots("topic", "<what is measured per part, and the Q- it watches>\037<what wakes whom, citing the Q- whose band it guards>\037<how an incident is noticed, handled and closed; where its record lives>")
            slots("topic", "<Claim, citing J, R or Q>\037<how the parts achieve it>\037<what must hold; link observed facts>\037<D-NN, which holds the alternatives and when to revisit>")
            slots("topic", "| <TEST> |\037| <PROD> |\037<early access: new features tried and validated first>\037<its own account, subscription or project>\037<sample, then invited users\047 real data>\037<owner, invited testers>\037<each merge to main>")
            slots("topic", "<the product for everyone>\037<a dedicated account, subscription or project; or TEST\047s at first, for a small product>\037| <real data> |\037| <anyone> |\037<a release validated in TEST>")
            slots("topic", "<what they never share: data, secrets, identities; accounts once separate>\037<never moves, or only by its owner\047s action after a summary>\037<build, test, deploy to each environment, roll back>\037- <Tool or job>:\037<what it does, who runs it>\037Code: <path>")
            slots("part", "P<n>\037<part name>\037<what runs or ships, and where>\037**Code**: <paths>\037<What it does for the journeys, R and Q its architecture parts-table row cites.>\037### <component>\037<What it does for the part.>")
            slots("part", "<title>**:\037<observable behavior>\037Test: <name or unenforced>\037<always true>\037<test, analyzer, metric or unenforced>\037- <Interface>:\037<compatibility promise, failure meaning>\037<link to code>\037<When a dependency fails, what this part does>\037<this part\047s share of its band>\037- <...>")
            slots("decision", "# <title>\037D-NN <title>\037<owner, date: \"<words>\"; or agent, date>\037<the choice and its evidence>\037<each option and why it was rejected>\037Revisit when**: <condition>")
            slots("decision", "<The choice and its evidence.>\037<Each option and why it was rejected, including a managed or off-the-shelf option.>\037<Conditions that reopen it.>")
            slots("journey", "# J-<NN>\037<journey> (hypothesis)\037<persona from product.md>\037**Area**: <area>\037<what they touch>\037<What they are trying to get done, and why it matters to them.>")
            slots("journey", "<Where and when: place, device, connection, time pressure, what they already know. Their context, never delivery status: what is built or planned lives in R and Q markers and changes.>\037<What they do and what they see, from their side.>\037**<situation>**:\037<what changes, and what they see>\037<The observable result, for them and for the business.>")
            slots("lifecycle", "# <Product> — lifecycle\037**Now**: <stage>\037since <date>\037**Next**: <stage>\037## <Stage> (now)\037## <Next stage>")
            slots("lifecycle", "<what this stage proves, and for whom>\037<who uses it: the owner, invited testers, anyone>\037<the environment it runs in (architecture/environments.md); sample or real data>\037<support, the quality bands enforced, compatibility>\037<observable criteria>\037**: <...>.")
            slots("requirements", "# <Product> — requirements\037## <Area>\037<title>**\037<what must be true>\037<owner, date: \"<words>\"; observed; or the change that introduced it>\037<L0 decisions intentionally not made; agents choose them without asking.>")
            slots("qualities", "# <Product> — qualities\037<title>**\037<band and method>\037<test, metric, owner review or unenforced>")
            slots("constraints", "# <Product> — constraints\037<title>**:\037**: <rule>.\037Why: <risk>\037<the parts and journeys it binds (P2, J-03), or all>\037<owner, date: \"<words>\"; a policy link; or the change that introduced it>\037Revisit when: <condition>\037Exception: <how to ask>")
            slots("non-goals", "# <Product> — non-goals\037<title>**:\037<what it does not do>\037Why: <reason>\037Revisit when: <condition>")
            slots("design", "# <Product> — UI design\037<Owner\047s words, with date and source.>\037<What gets attention first, and how should the UI be organized?>\037<What should the UI say, and what should it leave unsaid?>\037- <YYYY-MM-DD> —\037<decision or correction and its scope>\037<owner message or review>")
        }
        function family(path) {
            if (path == ".prdkit/memory/constitution.md") return "constitution"
            if (path == ".prdkit/memory/agents.md") return "agents"
            if (path == ".prdkit/memory/config.md") return "config"
            if (path == ".prdkit/history/archive.md") return "archive"
            if (path ~ /^\.prdkit\/agents\//) return "agent-definition"
            if (path == "specs/inbox.md") return "inbox"
            if (path == "specs/records.md") return "records"
            if (path == "specs/authority.md") return "authority"
            if (path == "specs/SPEC.md") return "spec"
            if (path ~ /^specs\/(product\.md|product\/users(\.md|\/))/) return "product"
            if (path == "specs/architecture.md") return "architecture"
            if (path == "specs/design.md") return "design"
            if (path ~ /^specs\/changes\//) return "change"
            if (path ~ /^specs\/parts\//) return "part"
            if (path ~ /^specs\/(decisions\/|architecture\/decisions(\.md|\/))/) return "decision"
            if (path ~ /^specs\/architecture\//) return "topic"
            if (path ~ /^specs\/product\/journeys\//) return "journey"
            if (path ~ /^specs\/product\/(lifecycle|requirements|qualities|constraints|non-goals)(\.md|\/)/) {
                split(path, components, /[\/.]/)
                return components[3]  # kit topic or one of its split pieces
            }
            return ""
        }
        # Match a complete literal, even when the template wraps it across up to three
        # lines. Count a slot once per starting line, not once per lookbehind window.
        function scan(group, line,   i, body, prefix, rest, at, offset, start, token) {
            prefix = prev2 prev1
            body = prefix line
            for (i = 1; i <= count[group]; i++) {
                token = literal[group, i]
                rest = body; offset = 0
                while ((at = index(rest, token)) > 0) {
                    offset += at
                    if (offset + length(token) > length(prefix) + 1) {
                        start = FNR - (offset <= length(prev2) ? 2 : (offset <= length(prefix) ? 1 : 0))
                        printf "P\037%s:%d (%s)\n", FILENAME, start, token
                        break
                    }
                    rest = substr(rest, at + length(token))
                    offset += length(token) - 1
                }
            }
            prev2 = prev1; prev1 = line " "
        }
        FNR == 1 {
            group = family(FILENAME)
            metadata_code = metadata_comment = section = code_group = prev1 = prev2 = ""
            frontmatter = 0
        }
        group == "" { next }
        {
            line = $0; sub(/\r$/, "", line)
            if (group == "agent-definition" && line == "---" && (FNR == 1 || frontmatter)) {
                frontmatter = (FNR == 1)
                next
            }
            if (frontmatter) {
                for (i = 1; i <= count["agent-frontmatter"]; i++)
                    if (line == literal["agent-frontmatter", i]) printf "P\037%s:%d (%s)\n", FILENAME, FNR, line
                next
            }
            was_code = metadata_code
            if (metadata_skip(line)) {
                if (was_code != "" && metadata_code != "" && code_group != "") {
                    sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
                    if (code_group != "commands" || line == commands) scan(code_group, line)
                    next
                }
                code_group = prev1 = prev2 = ""
                if (was_code == "" && metadata_code != "") {
                    if (group == "constitution" && section == "commands") code_group = "commands"
                    if ((group == "product" || group == "architecture") &&
                        line ~ /^ ? ? ?(```+|~~~+)mermaid[[:space:]]*$/) code_group = group "-diagram"
                }
                next
            }
            if (line ~ /^[[:space:]]*>/) { prev1 = prev2 = ""; next }
            gsub(/<!--([^-]|-[^-]|--[^>])*-->/, "", line)
            if ((comment_at = index(line, "<!--")) > 0) {
                metadata_comment = 1
                line = substr(line, 1, comment_at - 1)
            }
            if (line ~ /^ ? ? ?##?([[:space:]]|$)/) {
                section = ""
                if (tolower(line) ~ /^ ? ? ?##[[:space:]]+configuration([[:space:]]*|[[:space:]]+#+[[:space:]]*)$/) section = "config"
                if (line ~ /^ ? ? ?##[[:space:]]+Commands([[:space:]]*|[[:space:]]+#+[[:space:]]*)$/) section = "commands"
            }
            if (group == "config" && (section != "config" ||
                line !~ /^[[:blank:]]*-[[:blank:]]+(review-publishers|review-owner):/)) next
            if (group == "records") {
                if (line !~ /^(HOLD|WAIVER|ATTEST|DEPLOY)[[:blank:]]/) next
                # A reason may be verbatim owner words; only an entire
                # fill-in value is residue there, never a token inside a quote.
                if ((at = index(line, " — ")) > 0) {
                    reason = substr(line, at + length(" — "))
                    sub(/[[:space:]]+$/, "", reason)
                    for (i = 1; i <= count["record-reason"]; i++)
                        if (reason == literal["record-reason", i]) printf "P\037%s:%d (%s)\n", FILENAME, FNR, reason
                    line = substr(line, 1, at - 1)
                }
                prev1 = prev2 = ""
            }
            if (group == "constitution") {
                value = line
                if (sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", value) && index(value, marker))
                    printf "D\037%s:%d (Rigor)\n", FILENAME, FNR
            }
            # Keep an empty line and section boundaries from joining unrelated text.
            gsub(/[[:space:]]+/, " ", line)
            sub(/^ /, "", line); sub(/ $/, "", line)
            if (line == "" || line ~ /^#/) prev1 = prev2 = ""
            if (line != "") scan(group, line)
        }' "${files[@]}"
)
