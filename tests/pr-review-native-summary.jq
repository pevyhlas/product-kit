# Explicit projection, not a free-form log sink. No input string is reflected.
def number_in($lo;$hi): type=="number" and floor==. and . >= $lo and . <= $hi;
def status: .==null or number_in(0;255);
def boolean: type=="boolean";
def maybe_boolean: .==null or boolean;
def fields: [scan("[^[:space:]]+")];
def pid: number_in(1;2147483647);
def numeric: try tonumber catch null;
def role:
    if type=="object" and (.present|maybe_boolean) and (.live|maybe_boolean) and (.in_group|maybe_boolean)
    then {present,in_group,live} else {present:null,in_group:null,live:null} end;
def snapshot($events;$stage):
    [$events[]|select(.kind=="snapshot" and .stage==$stage)] as $s |
    if ($s|length)==1 and $s[0].available==true and
       ($s[0].live_members|number_in(0;32)) and
       ($s[0].owned_live==null or ($s[0].owned_live|number_in(0;5)))
    then $s[0]|{available:true,leader:(.leader|role),gate:(.gate|role),descendant:(.descendant|role),
        descendant_parent_is_gate:(if (.descendant_parent_is_gate|maybe_boolean) then .descendant_parent_is_gate else null end),
        live_members,owned_live}
    else {available:false,leader:{present:null,in_group:null,live:null},gate:{present:null,in_group:null,live:null},
        descendant:{present:null,in_group:null,live:null},descendant_parent_is_gate:null,live_members:null,owned_live:null} end;
def signal($events;$name):
    [$events[]|select(.kind=="signal" and .signal==$name)] as $s |
    if ($s|length)==1 and ($s[0].rc|number_in(0;255)) then $s[0].rc else null end;
def observation:
    (try (.gate|fields) catch []) as $g |
    (try (.owned|fields) catch []) as $o |
    (try (.descendant|fields) catch []) as $d |
    (try (.terminal|fields) catch []) as $t |
    (try [.events|split("\n")[]|select(length>0)|fromjson] catch []) as $events |
    (($t|length)==2 and ($t[0]|numeric|number_in(0;32)) and
       ($t[1]=="false" or $t[1]=="true")) as $terminal |
    ($terminal and $t[1]=="false" and ($t[0]|numeric)==($events|length) and
       all(range(0;$events|length); . as $i | $events[$i].seq==($i+1))) as $collected |
    (($g|length)==3 and ($g[0]|numeric|pid) and ($g[1]|numeric|pid) and
      ($o|length)==6 and all($o[]; numeric|pid) and
      ($d|length)==2 and ($d[0]|numeric|pid) and ($d[1]|numeric|number_in(0;255))) as $identities |
    [$events[]|select(.kind=="wait")] as $waits |
    [$events[]|select(.kind=="transfer")] as $transfers |
    {schema:"native-case-v1",evidence:"incomplete",kernel_status_proven:false,
     overflow:(.overflow==true or ($events|length)>32 or ($waits|length)>16),
     collection:{terminal_available:$terminal,complete:$collected,
       error:(if $terminal then $t[1]=="true" else null end)},
     identity:{
        leader_is_gate:(if $identities then $g[0]==$o[1] else null end),
        gate_parent_is_leader:(if $identities then $g[1]==$o[1] else null end),
        gate_parent_is_launcher:(if $identities then $g[1]==$o[0] else null end),
        gate_ignores_term:(if $g[2]=="true" then true elif $g[2]=="false" then false else null end),
        descendant_ready:(if $identities then true else null end),
        descendant_term_rc:(if $identities then $d[1]|tonumber else null end)},
     before_term:snapshot($events;"term"),before_kill:snapshot($events;"kill"),
     signals:{TERM:signal($events;"TERM"),KILL:signal($events;"KILL")},
     waits:[$waits[:16][]|
        if (.status|status) and (.before|number_in(0;255)) and (.generation|number_in(0;255)) and
           (.critical|boolean) and (.finishing|boolean) and (.alive|boolean) and (.native_exit|status)
        then {role:"leader",status,before,generation,critical,finishing,alive,native_exit}
        else {role:"leader",status:null,before:null,generation:null,critical:null,finishing:null,alive:null,native_exit:null} end],
     transfer:(if ($transfers|length)==1 and ($transfers[0].native_exit|status) and
         ($transfers[0].group_exit|status) and ($transfers[0].pending|boolean)
         then $transfers[0]|{native_exit,group_exit,pending}
         else {native_exit:null,group_exit:null,pending:null} end),
     before_delete:snapshot($events;"remove"),
     object:{available:(.object.available==true),
       equal:(if .object.available==true and (.object.equal|boolean) then .object.equal else null end),
       extension_keep:(if .object.available==true and (.object.extension_keep|boolean) then .object.extension_keep else null end),
       digest:(if .object.available==true and (.object.digest|type)=="string" and
         (.object.digest|length)==40 and (.object.digest|test("[^a-f0-9]")|not)
         then .object.digest else null end)}} |
    if $collected and $identities and (.overflow|not) and (.identity.gate_ignores_term|boolean) and
       .before_term.available and .before_kill.available and .before_delete.available and
       .before_term.owned_live!=null and .before_kill.owned_live!=null and .before_delete.owned_live!=null and
       (.signals.TERM!=null) and (.signals.KILL!=null) and
       (.waits|length)>0 and all(.waits[]; .status!=null) and .transfer.native_exit!=null and
       .transfer.group_exit!=null and .object.available and .object.equal!=null and
       .object.extension_keep!=null and .object.digest!=null and
       all([.before_term.leader,.before_term.gate,.before_term.descendant,
            .before_kill.leader,.before_kill.gate,.before_kill.descendant,
            .before_delete.leader,.before_delete.gate,.before_delete.descendant][]; .present!=null and .live!=null)
    then .evidence="complete" else . end;
try observation catch {schema:"native-case-v1",evidence:"unavailable"}
