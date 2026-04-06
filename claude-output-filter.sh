#!/usr/bin/env bash
set -euo pipefail

block_kind=()
block_tool_name=()
block_tool_input=()

current_text_kind=
current_text_index=
current_text_open=0

json_text() {
  local expr=$1
  local payload=$2

  printf '%s\n' "$payload" | jq -r "$expr // empty"
}

json_compact() {
  local expr=$1
  local payload=$2

  printf '%s\n' "$payload" | jq -c "$expr"
}

is_numeric() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

finish_text_block() {
  if [[ "$current_text_open" == "1" ]]; then
    printf '\n'
  fi

  current_text_open=0
  current_text_kind=
  current_text_index=
}

emit_text_delta() {
  local kind=$1
  local index=$2
  local text=$3
  local label

  [[ -n "$text" ]] || return 0

  case "$kind" in
    thinking) label="Thinking" ;;
    text) label="Text" ;;
    *) return 0 ;;
  esac

  if [[ "$current_text_kind" != "$kind" || "$current_text_index" != "$index" ]]; then
    finish_text_block
    printf '%s:\n' "$label"
    current_text_kind=$kind
    current_text_index=$index
  fi

  printf '%s' "$text"
  current_text_open=1
}

print_pretty_json() {
  local payload=$1

  if printf '%s\n' "$payload" | jq . >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq .
  else
    printf '%s\n' "$payload"
  fi
}

extract_json_string_field() {
  local payload=$1
  local field=$2
  local escaped=

  if [[ -n "$payload" ]] && printf '%s\n' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -r --arg field "$field" '.[$field] // empty'
    return 0
  fi

  if [[ "$payload" =~ \"${field}\"[[:space:]]*:[[:space:]]*\"(([^\"\\]|\\.)*)\" ]]; then
    escaped=${BASH_REMATCH[1]}
    printf '"%s"\n' "$escaped" | jq -r .
    return 0
  fi

  printf '\n'
}

basename_or_original() {
  local value=$1

  [[ -n "$value" ]] || return 0

  if [[ "$value" == */* ]]; then
    printf '%s\n' "${value##*/}"
  else
    printf '%s\n' "$value"
  fi
}

extract_tool_detail() {
  local name=$1
  local input_payload=$2
  local description=
  local command=
  local path=

  case "$name" in
    Read)
      path=$(extract_json_string_field "$input_payload" file_path)
      [[ -n "$path" ]] || path=$(extract_json_string_field "$input_payload" path)
      [[ -n "$path" ]] || path=$(extract_json_string_field "$input_payload" filepath)
      [[ -n "$path" ]] || path=$(extract_json_string_field "$input_payload" filename)
      if [[ -n "$path" ]]; then
        basename_or_original "$path"
        return 0
      fi
      ;;
  esac

  description=$(extract_json_string_field "$input_payload" description)
  command=$(extract_json_string_field "$input_payload" command)

  if [[ -n "$description" ]]; then
    printf '%s\n' "$description"
  elif [[ -n "$command" ]]; then
    printf '%s\n' "$command"
  else
    printf '\n'
  fi
}

emit_tool_call() {
  local name=$1
  local input_payload=${2:-}
  local detail=

  finish_text_block

  detail=$(extract_tool_detail "$name" "$input_payload")

  if [[ -n "$detail" ]]; then
    printf 'Tool call: %s - %s\n' "${name:-<unknown>}" "$detail"
  else
    printf 'Tool call: %s\n' "${name:-<unknown>}"
  fi
}

reset_block_state() {
  local index=$1

  block_kind[$index]=
  block_tool_name[$index]=
  block_tool_input[$index]=
}

render_complete_block() {
  local block_json=$1
  local block_type text name input_payload

  block_type=$(json_text '.type' "$block_json")
  case "$block_type" in
    thinking)
      finish_text_block
      text=$(json_text '.thinking // .text' "$block_json")
      [[ -n "$text" ]] || return 0
      printf 'Thinking:\n%s\n' "$text"
      ;;
    text)
      finish_text_block
      text=$(json_text '.text' "$block_json")
      [[ -n "$text" ]] || return 0
      printf 'Text:\n%s\n' "$text"
      ;;
    tool_use|server_tool_use|mcp_tool_use)
      name=$(json_text '.name' "$block_json")
      input_payload=$(json_compact '.input' "$block_json")
      [[ "$input_payload" == "{}" ]] && input_payload=
      emit_tool_call "$name" "$input_payload"
      ;;
  esac
}

render_complete_blocks() {
  local blocks_json=$1
  local block_json

  while IFS= read -r block_json; do
    [[ -n "$block_json" ]] || continue
    render_complete_block "$block_json"
  done < <(printf '%s\n' "$blocks_json" | jq -c '.[]?')
}

handle_content_block_start() {
  local event_json=$1
  local index block_type initial_text name input_payload

  index=$(json_text '.index' "$event_json")
  is_numeric "$index" || return 0

  block_type=$(json_text '.content_block.type' "$event_json")
  block_kind[$index]=$block_type

  case "$block_type" in
    thinking)
      initial_text=$(json_text '.content_block.thinking // .content_block.text' "$event_json")
      emit_text_delta thinking "$index" "$initial_text"
      ;;
    text)
      initial_text=$(json_text '.content_block.text' "$event_json")
      emit_text_delta text "$index" "$initial_text"
      ;;
    tool_use|server_tool_use|mcp_tool_use)
      name=$(json_text '.content_block.name' "$event_json")
      input_payload=$(json_compact '.content_block.input // empty' "$event_json")
      [[ "$input_payload" == "{}" ]] && input_payload=
      block_tool_name[$index]=$name
      block_tool_input[$index]=$input_payload
      ;;
  esac
}

handle_content_block_delta() {
  local event_json=$1
  local index delta_type partial_json kind

  index=$(json_text '.index' "$event_json")
  is_numeric "$index" || return 0

  delta_type=$(json_text '.delta.type' "$event_json")
  case "$delta_type" in
    thinking_delta)
      emit_text_delta thinking "$index" "$(json_text '.delta.thinking' "$event_json")"
      ;;
    text_delta)
      emit_text_delta text "$index" "$(json_text '.delta.text' "$event_json")"
      ;;
    input_json_delta)
      partial_json=$(json_text '.delta.partial_json // .delta.text' "$event_json")
      kind=${block_kind[$index]:-}
      if [[ "$kind" == "tool_use" || "$kind" == "server_tool_use" || "$kind" == "mcp_tool_use" ]]; then
        block_tool_input[$index]="${block_tool_input[$index]:-}${partial_json}"
      fi
      ;;
  esac
}

handle_content_block_stop() {
  local event_json=$1
  local index kind input_payload name

  index=$(json_text '.index' "$event_json")
  is_numeric "$index" || return 0

  kind=${block_kind[$index]:-}
  case "$kind" in
    thinking|text)
      if [[ "$current_text_index" == "$index" ]]; then
        finish_text_block
      fi
      ;;
    tool_use|server_tool_use|mcp_tool_use)
      input_payload=${block_tool_input[$index]:-}
      name=${block_tool_name[$index]:-}
      if [[ -n "$name" || -n "$input_payload" ]]; then
        emit_tool_call "${name:-<unknown>}" "$input_payload"
      fi
      ;;
  esac

  reset_block_state "$index"
}

render_json_record() {
  local record_json=$1
  local record_type subtype error_text is_error

  record_type=$(json_text '.type' "$record_json")
  subtype=$(json_text '.subtype' "$record_json")
  is_error=$(json_text '.is_error' "$record_json")

  case "$record_type" in
    content_block_start)
      handle_content_block_start "$record_json"
      return 0
      ;;
    content_block_delta)
      handle_content_block_delta "$record_json"
      return 0
      ;;
    content_block_stop)
      handle_content_block_stop "$record_json"
      return 0
      ;;
  esac

  if [[ "$record_type" == "assistant" ]]; then
    if printf '%s\n' "$record_json" | jq -e '.message.content? | arrays' >/dev/null 2>&1; then
      render_complete_blocks "$(json_compact '.message.content' "$record_json")"
      return 0
    fi
    if printf '%s\n' "$record_json" | jq -e '.content? | arrays' >/dev/null 2>&1; then
      render_complete_blocks "$(json_compact '.content' "$record_json")"
      return 0
    fi
  fi

  if [[ "$record_type" == "error" || "$is_error" == "true" || "$subtype" == error* ]]; then
    error_text=$(json_text '((.errors // []) | map(tostring) | join("\n")) // .error // .message // .stderr // .result' "$record_json")
    if [[ -n "$error_text" ]]; then
      finish_text_block
      printf 'Error: %s\n' "$error_text"
    fi
  fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if ! printf '%s\n' "$line" | jq -e . >/dev/null 2>&1; then
    finish_text_block
    printf '%s\n' "$line"
    continue
  fi

  render_json_record "$line"
done

finish_text_block
