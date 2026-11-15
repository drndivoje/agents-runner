# One CSV row (or the header) describing a run, from:
#   $run      runner facts (strings, passed with --argjson run)
#   $result   [result.json] or []          (--slurpfile; the final stream-json "result" event)
#   $events   [transcript events]          (--slurpfile; every stream-json event)
#   $header   "true" → print the header line instead of the row
# Column order = key order below. Changing it makes run-agent.sh archive the old CSV.

def num: if . == null then 0 else . end;
def str: if . == null then "" else tostring end;

($result[0] // {}) as $r
| ($r.usage // {}) as $u
| ($events | map(select(.type == "system" and .subtype == "init")) | first // {}) as $init
| [ $events[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name ] as $tools
| [ $events[] | select(.type == "user") | .message.content[]?
    | select(type == "object" and .type == "tool_result" and .is_error == true) ] as $tool_errors
| ($r.modelUsage // {}) as $mu
| {
    # ── run (from the runner) ───────────────────────────────────────────
    run_id:                      $run.run_id,
    started_at:                  $run.started_at,
    finished_at:                 $run.finished_at,
    repo_name:                   $run.repo_name,
    repo:                        $run.repo,
    agent:                       $run.agent,
    claude_agent:                $run.claude_agent,
    status:                      $run.status,
    exit_code:                   $run.exit_code,
    output_url:                  $run.output_url,
    wall_seconds:                $run.wall_seconds,
    pre_seconds:                 $run.pre_seconds,
    claude_seconds:              $run.claude_seconds,
    check_seconds:               $run.check_seconds,
    check_exit_code:             $run.check_exit_code,
    post_seconds:                $run.post_seconds,
    claude_exit_code:            $run.claude_exit_code,
    model_setting:               $run.model_setting,
    max_turns:                   $run.max_turns,
    timeout_minutes:             $run.timeout_minutes,
    # ── session (stream-json init event) ────────────────────────────────
    model:                       ($init.model | str),
    models_used:                 ($mu | keys | join(";")),
    claude_code_version:         ($init.claude_code_version | str),
    api_key_source:              ($init.apiKeySource | str),
    permission_mode:             ($init.permissionMode | str),
    session_id:                  (($r.session_id // $init.session_id) | str),
    # ── outcome (result event) ──────────────────────────────────────────
    subtype:                     ($r.subtype | str),
    is_error:                    ($r.is_error | str),
    terminal_reason:             ($r.terminal_reason | str),
    stop_reason:                 ($r.stop_reason | str),
    api_error_status:            ($r.api_error_status | str),
    safety_stops:                ($r.safety_stops | num),
    # ── time ────────────────────────────────────────────────────────────
    duration_ms:                 ($r.duration_ms | num),
    duration_api_ms:             ($r.duration_api_ms | num),
    num_turns:                   ($r.num_turns | num),
    api_retries:                 ([ $events[] | select(.type == "system" and .subtype == "api_retry") ] | length),
    # ── tokens ──────────────────────────────────────────────────────────
    input_tokens:                ($u.input_tokens | num),
    output_tokens:               ($u.output_tokens | num),
    thinking_tokens:             ($u.output_tokens_details.thinking_tokens | num),
    cache_creation_input_tokens: ($u.cache_creation_input_tokens | num),
    cache_creation_5m_tokens:    ($u.cache_creation.ephemeral_5m_input_tokens | num),
    cache_creation_1h_tokens:    ($u.cache_creation.ephemeral_1h_input_tokens | num),
    cache_read_input_tokens:     ($u.cache_read_input_tokens | num),
    total_tokens:                (($u.input_tokens | num) + ($u.output_tokens | num)
                                  + ($u.cache_creation_input_tokens | num) + ($u.cache_read_input_tokens | num)),
    # API-equivalent price; not billed on a Pro subscription, useful to compare runs.
    total_cost_usd:              ($r.total_cost_usd | num),
    # ── tools ───────────────────────────────────────────────────────────
    tool_calls:                  ($tools | length),
    tool_errors:                 ($tool_errors | length),
    tools_used:                  ($tools | group_by(.) | map("\(.[0]):\(length)") | join(";")),
    permission_denials:          ($r.permission_denials // [] | length),
    web_search_requests:         ($u.server_tool_use.web_search_requests | num),
    web_fetch_requests:          ($u.server_tool_use.web_fetch_requests | num),
    subagents_spawned:           ($r.subagent_stats.spawned | num),
    subagents_failed:            ($r.subagent_stats.failed | num),
    # ── service ─────────────────────────────────────────────────────────
    service_tier:                ($u.service_tier | str),
    speed:                       ($u.speed | str),
    inference_geo:               ($u.inference_geo | str),
    result_chars:                ($r.result // "" | length)
  }
| if $header == "true" then keys_unsorted else [ .[] ] end
| @csv
