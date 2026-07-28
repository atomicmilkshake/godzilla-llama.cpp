#include "../tools/server/server-task.h"
#include "../tools/server/server-chat.h"

#undef NDEBUG
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>

static common_chat_parser_params copilot_parser_params() {
    common_chat_parser_params params;
    params.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
    params.reasoning_promote_to_content = false;
    return params;
}

static server_task_result_cmpl_partial make_partial(
        task_result_state                   & state,
        int                                   n_decoded,
        std::vector<common_chat_msg_diff>     diffs) {
    server_task_result_cmpl_partial partial;
    partial.is_updated = true;
    partial.res_type = TASK_RESPONSE_TYPE_OAI_CHAT;
    partial.n_decoded = n_decoded;
    partial.index = 0;
    partial.oaicompat_cmpl_id = "cmpl-test";
    partial.oaicompat_model = "test-model";
    partial.chat_parser_params = state.chat_parser_params;
    partial.p_copilot_content_coalesce_buffer = &state.copilot_content_coalesce_buffer;
    partial.oaicompat_msg_diffs = std::move(diffs);
    return partial;
}

static std::vector<std::string> collect_content_deltas(const json & chunks) {
    std::vector<std::string> out;
    for (const auto & chunk : chunks) {
        const auto & choices = chunk.at("choices");
        if (choices.empty()) {
            continue;
        }
        const auto & delta = choices.at(0).at("delta");
        if (delta.contains("content") && !delta.at("content").is_null()) {
            out.push_back(delta.at("content").get<std::string>());
        }
    }
    return out;
}

static std::vector<std::string> collect_reasoning_deltas(const json & chunks) {
    std::vector<std::string> out;
    for (const auto & chunk : chunks) {
        const auto & choices = chunk.at("choices");
        if (choices.empty()) {
            continue;
        }
        const auto & delta = choices.at(0).at("delta");
        if (delta.contains("reasoning_content") && !delta.at("reasoning_content").is_null()) {
            out.push_back(delta.at("reasoning_content").get<std::string>());
        }
    }
    return out;
}

static void test_coalesce_accumulates_across_partials_until_boundary() {
    common_chat_parser_params params = copilot_parser_params();
    task_result_state state(params);

    const std::vector<std::string> tokens = {"H", "e", "l", "l", "o"};
    for (size_t i = 0; i < tokens.size(); ++i) {
        common_chat_msg_diff diff;
        diff.content_delta = tokens[i];
        auto partial = make_partial(state, (int) i + 2, {diff});
        const json chunks = partial.to_json_oaicompat_chat();
        assert(collect_content_deltas(chunks).empty());
    }

    common_chat_msg_diff space_diff;
    space_diff.content_delta = " ";
    auto partial = make_partial(state, 7, {space_diff});
    const json chunks = partial.to_json_oaicompat_chat();
    const auto content = collect_content_deltas(chunks);
    assert(content.size() == 1);
    assert(content[0] == "Hello ");
}

static void test_reasoning_not_promoted_when_disabled() {
    common_chat_parser_params params = copilot_parser_params();
    task_result_state state(params);

    common_chat_msg_diff diff;
    diff.reasoning_content_delta = "internal thought";
    auto partial = make_partial(state, 2, {diff});
    const json chunks = partial.to_json_oaicompat_chat();

    assert(collect_content_deltas(chunks).empty());
    const auto reasoning = collect_reasoning_deltas(chunks);
    assert(reasoning.size() == 1);
    assert(reasoning[0] == "internal thought");
}

static void test_stream_end_flushes_remainder() {
    common_chat_parser_params params = copilot_parser_params();
    task_result_state state(params);

    common_chat_msg_diff diff;
    diff.content_delta = "wor";
    auto partial = make_partial(state, 5, {diff});
    (void) partial.to_json_oaicompat_chat();
    assert(state.copilot_content_coalesce_buffer == "wor");

    server_task_result_cmpl_final final_res;
    final_res.is_updated = true;
    final_res.stream = true;
    final_res.res_type = TASK_RESPONSE_TYPE_OAI_CHAT;
    final_res.index = 0;
    final_res.oaicompat_cmpl_id = "cmpl-test";
    final_res.oaicompat_model = "test-model";
    final_res.generation_params.chat_parser_params = params;
    final_res.p_copilot_content_coalesce_buffer = &state.copilot_content_coalesce_buffer;
    final_res.include_usage = false;
    final_res.stop = STOP_TYPE_EOS;

    const json chunks = final_res.to_json_oaicompat_chat_stream();
    const auto content = collect_content_deltas(chunks);
    assert(content.size() == 1);
    assert(content[0] == "wor");
    assert(state.copilot_content_coalesce_buffer.empty());
}

static void test_coalesce_emits_on_long_buffer() {
    common_chat_parser_params params = copilot_parser_params();
    task_result_state state(params);

    common_chat_msg_diff diff;
    diff.content_delta = std::string(32, 'x');
    auto partial = make_partial(state, 3, {diff});
    const json chunks = partial.to_json_oaicompat_chat();
    const auto content = collect_content_deltas(chunks);
    assert(content.size() == 1);
    assert(content[0].size() == 32);
}

int main() {
    test_coalesce_accumulates_across_partials_until_boundary();
    test_reasoning_not_promoted_when_disabled();
    test_stream_end_flushes_remainder();
    test_coalesce_emits_on_long_buffer();
    return 0;
}
