llama_add_compile_flags()

function(llama_build source)
    set(TEST_SOURCES ${source} ${ARGN})

    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_TARGET ${LLAMA_TEST_NAME})
    else()
        get_filename_component(TEST_TARGET ${source} NAME_WE)
    endif()

    add_executable(${TEST_TARGET} ${TEST_SOURCES})
    target_link_libraries(${TEST_TARGET} PRIVATE llama llama-common)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS ${TEST_TARGET} RUNTIME)
    endif()
endfunction()

function(llama_test target)
    include(CMakeParseArguments)
    set(options)
    set(oneValueArgs NAME LABEL WORKING_DIRECTORY)
    set(multiValueArgs ARGS)
    cmake_parse_arguments(LLAMA_TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if (NOT DEFINED LLAMA_TEST_LABEL)
        set(LLAMA_TEST_LABEL "main")
    endif()
    if (NOT DEFINED LLAMA_TEST_WORKING_DIRECTORY)
        set(LLAMA_TEST_WORKING_DIRECTORY .)
    endif()
    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_NAME ${LLAMA_TEST_NAME})
    else()
        set(TEST_NAME ${target})
    endif()

    set(TEST_TARGET ${target})

    add_test(
        NAME ${TEST_NAME}
        WORKING_DIRECTORY ${LLAMA_TEST_WORKING_DIRECTORY}
        COMMAND $<TARGET_FILE:${TEST_TARGET}>
        ${LLAMA_TEST_ARGS})

    set_property(TEST ${TEST_NAME} PROPERTY LABELS ${LLAMA_TEST_LABEL})
endfunction()

function(llama_test_cmd target)
    include(CMakeParseArguments)
    set(options)
    set(oneValueArgs NAME LABEL WORKING_DIRECTORY)
    set(multiValueArgs ARGS)
    cmake_parse_arguments(LLAMA_TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if (NOT DEFINED LLAMA_TEST_LABEL)
        set(LLAMA_TEST_LABEL "main")
    endif()
    if (NOT DEFINED LLAMA_TEST_WORKING_DIRECTORY)
        set(LLAMA_TEST_WORKING_DIRECTORY .)
    endif()
    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_NAME ${LLAMA_TEST_NAME})
    else()
        set(TEST_NAME ${target})
    endif()

    add_test(
        NAME ${TEST_NAME}
        WORKING_DIRECTORY ${LLAMA_TEST_WORKING_DIRECTORY}
        COMMAND ${target}
        ${LLAMA_TEST_ARGS})

    set_property(TEST ${TEST_NAME} PROPERTY LABELS ${LLAMA_TEST_LABEL})
endfunction()

# Builds and runs a test source file.
# Optional args:
# - NAME: name of the executable & test target (defaults to the source file name without extension)
# - LABEL: label for the test (defaults to main)
# - ARGS: arguments to pass to the test executable
# - WORKING_DIRECTORY
function(llama_build_and_test source)
    include(CMakeParseArguments)
    set(options)
    set(oneValueArgs NAME LABEL WORKING_DIRECTORY)
    set(multiValueArgs ARGS)
    cmake_parse_arguments(LLAMA_TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    set(TEST_SOURCES ${source} ${LLAMA_TEST_UNPARSED_ARGUMENTS} get-model.cpp)

    if (NOT DEFINED LLAMA_TEST_LABEL)
        set(LLAMA_TEST_LABEL "main")
    endif()
    if (NOT DEFINED LLAMA_TEST_WORKING_DIRECTORY)
        set(LLAMA_TEST_WORKING_DIRECTORY .)
    endif()
    if (DEFINED LLAMA_TEST_NAME)
        set(TEST_TARGET ${LLAMA_TEST_NAME})
    else()
        get_filename_component(TEST_TARGET ${source} NAME_WE)
    endif()

    add_executable(${TEST_TARGET} ${TEST_SOURCES})
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS ${TEST_TARGET} RUNTIME)
    endif()
    target_link_libraries(${TEST_TARGET} PRIVATE llama-common)

    add_test(
        NAME ${TEST_TARGET}
        WORKING_DIRECTORY ${LLAMA_TEST_WORKING_DIRECTORY}
        COMMAND $<TARGET_FILE:${TEST_TARGET}>
        ${LLAMA_TEST_ARGS})

    set_property(TEST ${TEST_TARGET} PROPERTY LABELS ${LLAMA_TEST_LABEL})
endfunction()

find_package(Python3 COMPONENTS Interpreter QUIET)
if (Python3_Interpreter_FOUND)
    add_test(
        NAME test-turbo-mma-fused-static
        WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
        COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/tests/test-turbo-mma-fused-static.py)
    set_property(TEST test-turbo-mma-fused-static PROPERTY LABELS cuda)
    add_test(
        NAME test-issue41-regressions-static
        WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
        COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/tests/test-issue41-regressions-static.py)
    set_property(TEST test-issue41-regressions-static PROPERTY LABELS cuda)
    add_test(
        NAME test-hip-shuffle-compat-static
        WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
        COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/tests/test-hip-shuffle-compat-static.py)
    set_property(TEST test-hip-shuffle-compat-static PROPERTY LABELS hip)
    add_test(
        NAME test-hybrid-slot-erase
        WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/tools/server/tests
        COMMAND ${Python3_EXECUTABLE} -m pytest -v ${PROJECT_SOURCE_DIR}/tests/server/test_hybrid_slot_erase.py)
    set_property(TEST test-hybrid-slot-erase PROPERTY LABELS model python)
endif()

# build test-tokenizer-0 target once and add many tests
llama_build(test-tokenizer-0.cpp)

llama_test(test-tokenizer-0 NAME test-tokenizer-0-bert-bge          ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-bert-bge.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-command-r         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-command-r.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-deepseek-coder    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-deepseek-coder.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-deepseek-llm      ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-deepseek-llm.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-falcon            ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-falcon.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-gemma-4           ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gemma-4.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-gpt-2             ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gpt-2.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-llama-bpe         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-bpe.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-llama-spm         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-spm.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-mpt               ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-mpt.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-phi-3             ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-phi-3.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-qwen2             ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-qwen2.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-qwen35            ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-qwen35.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-refact            ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-refact.gguf)
llama_test(test-tokenizer-0 NAME test-tokenizer-0-starcoder         ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-starcoder.gguf)

if (NOT WIN32)
    llama_test_cmd(
        ${CMAKE_CURRENT_SOURCE_DIR}/test-tokenizers-repo.sh
        NAME test-tokenizers-ggml-vocabs
        WORKING_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}
        ARGS https://huggingface.co/ggml-org/vocabs ${PROJECT_SOURCE_DIR}/models/ggml-vocabs
    )
endif()

if (LLAMA_LLGUIDANCE)
    llama_build_and_test(test-grammar-llguidance.cpp ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-bpe.gguf)
endif ()

if (NOT WIN32 OR NOT BUILD_SHARED_LIBS)
    # these tests are disabled on Windows because they use internal functions not exported with LLAMA_API (when building with shared libraries)
    llama_build_and_test(test-sampling.cpp)
    llama_build_and_test(test-sampling-grammar.cpp ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-qwen2.gguf)
    llama_build_and_test(test-cuda-zero-dim-gemm.cpp ARGS ${PROJECT_SOURCE_DIR}/ggml/src/ggml-cuda/ggml-cuda.cu)
    llama_build_and_test(test-reasoning-budget.cpp)
    llama_build_and_test(test-grammar-parser.cpp)
    llama_build_and_test(test-grammar-integration.cpp)
    llama_build_and_test(test-llama-grammar.cpp)
    llama_build_and_test(test-chat.cpp WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
    target_include_directories(test-chat PRIVATE ${PROJECT_SOURCE_DIR}/tools/server ${PROJECT_SOURCE_DIR}/tools/mtmd)
    target_link_libraries(test-chat PRIVATE server-context)
    llama_build_and_test(test-server-loop-guard.cpp)
    target_include_directories(test-server-loop-guard PRIVATE ${PROJECT_SOURCE_DIR}/tools/server)
    target_link_libraries(test-server-loop-guard PRIVATE server-context)
    llama_build_and_test(test-server-copilot-coalesce.cpp)
    target_include_directories(test-server-copilot-coalesce PRIVATE ${PROJECT_SOURCE_DIR}/tools/server)
    target_link_libraries(test-server-copilot-coalesce PRIVATE server-context)
    # TODO: disabled on loongarch64 because the ggml-ci node lacks Python 3.8
    if (NOT ${CMAKE_SYSTEM_PROCESSOR} MATCHES "loongarch64")
        llama_build_and_test(test-json-schema-to-grammar.cpp   WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
        target_include_directories(test-json-schema-to-grammar PRIVATE ${PROJECT_SOURCE_DIR}/tools/server)
    endif()

    if (NOT GGML_BACKEND_DL)
        llama_build(test-quantize-stats.cpp)
    endif()

    llama_build(test-gbnf-validator.cpp)

    # build test-tokenizer-1-bpe target once and add many tests
    llama_build(test-tokenizer-1-bpe.cpp)

    # TODO: disabled due to slowness
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-aquila    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-aquila.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-falcon    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-falcon.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-gpt-2     ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gpt-2.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-gpt-neox  ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-gpt-neox.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-llama-bpe ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-bpe.gguf --ignore-merges)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-mpt       ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-mpt.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-refact    ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-refact.gguf)
    #llama_test(test-tokenizer-1-bpe NAME test-tokenizer-1-starcoder ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-starcoder.gguf)

    # build test-tokenizer-1-spm target once and add many tests
    llama_build(test-tokenizer-1-spm.cpp)

    llama_test(test-tokenizer-1-spm  NAME test-tokenizer-1-llama-spm ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-llama-spm.gguf)
    #llama_test(test-tokenizer-1-spm  NAME test-tokenizer-1-baichuan  ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-baichuan.gguf)

    # llama_build_and_test(test-double-float.cpp) # SLOW

    llama_build_and_test(test-llama-archs.cpp)
endif()

if (WIN32 AND BUILD_SHARED_LIBS)
    llama_build_and_test(test-sampling-grammar.cpp ARGS ${PROJECT_SOURCE_DIR}/models/ggml-vocab-qwen2.gguf)
    llama_build_and_test(test-cuda-zero-dim-gemm.cpp ARGS ${PROJECT_SOURCE_DIR}/ggml/src/ggml-cuda/ggml-cuda.cu)
    llama_build_and_test(test-reasoning-budget.cpp)
    llama_build_and_test(test-server-loop-guard.cpp)
    target_include_directories(test-server-loop-guard PRIVATE ${PROJECT_SOURCE_DIR}/tools/server)
    target_link_libraries(test-server-loop-guard PRIVATE server-context)
    llama_build_and_test(test-server-copilot-coalesce.cpp)
    target_include_directories(test-server-copilot-coalesce PRIVATE ${PROJECT_SOURCE_DIR}/tools/server)
    target_link_libraries(test-server-copilot-coalesce PRIVATE server-context)
endif()

llama_build_and_test(test-chat-peg-parser.cpp peg-parser/simple-tokenize.cpp)
llama_build_and_test(test-jinja.cpp)
llama_test(test-jinja NAME test-jinja-py ARGS -py LABEL python)
llama_build_and_test(test-chat-auto-parser.cpp WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
llama_build_and_test(test-chat-template.cpp)
llama_build_and_test(test-json-partial.cpp)
llama_build_and_test(test-log.cpp)
llama_build_and_test(
    test-peg-parser.cpp
    peg-parser/simple-tokenize.cpp
    peg-parser/test-basic.cpp
    peg-parser/test-gbnf-generation.cpp
    peg-parser/test-json-parser.cpp
    peg-parser/test-json-serialization.cpp
    peg-parser/test-python-dict-parser.cpp
    peg-parser/test-unicode.cpp
    peg-parser/tests.h
)
llama_build_and_test(test-regex-partial.cpp)

if (NOT ${CMAKE_SYSTEM_PROCESSOR} MATCHES "s390x")
    set(MODEL_NAME "tinyllamas/stories15M-q4_0.gguf")
    set(MODEL_HASH "SHA256=66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739")
else()
    set(MODEL_NAME "tinyllamas/stories15M-be.Q4_0.gguf")
    set(MODEL_HASH "SHA256=9aec857937849d976f30397e97eb1cabb53eb9dcb1ce4611ba8247fb5f44c65d")
endif()
set(MODEL_DEST "${CMAKE_BINARY_DIR}/${MODEL_NAME}")

add_test(NAME test-download-model COMMAND ${CMAKE_COMMAND}
    -DDEST=${MODEL_DEST}
    -DNAME=${MODEL_NAME}
    -DHASH=${MODEL_HASH}
    -P ${CMAKE_SOURCE_DIR}/cmake/download-models.cmake
)
set_tests_properties(test-download-model PROPERTIES FIXTURES_SETUP test-download-model)

llama_build_and_test(test-thread-safety.cpp ARGS -m "${MODEL_DEST}" -ngl 99 -p "The meaning of life is" -n 128 -c 256 -ub 32 -np 4 -t 2)
set_tests_properties(test-thread-safety PROPERTIES FIXTURES_REQUIRED test-download-model)

llama_build_and_test(test-arg-parser.cpp)
add_executable(test-kvarn test-kvarn.cpp ../src/llama-kvarn.cpp)
target_include_directories(test-kvarn PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_compile_features(test-kvarn PRIVATE cxx_std_17)
target_link_libraries(test-kvarn PRIVATE ggml)
if (LLAMA_TESTS_INSTALL)
    install(TARGETS test-kvarn RUNTIME)
endif()
add_test(NAME test-kvarn WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-kvarn>)
set_property(TEST test-kvarn PROPERTY LABELS main)
add_executable(test-triattention-cal-v2 test-triattention-cal-v2.cpp ../src/llama-triattention.cpp)
target_include_directories(test-triattention-cal-v2 PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_compile_features(test-triattention-cal-v2 PRIVATE cxx_std_17)
target_link_libraries(test-triattention-cal-v2 PRIVATE llama)
if (LLAMA_TESTS_INSTALL)
    install(TARGETS test-triattention-cal-v2 RUNTIME)
endif()
add_test(NAME test-triattention-cal-v2 WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-cal-v2>)
set_property(TEST test-triattention-cal-v2 PROPERTY LABELS main)
add_executable(test-triattention-iswa test-triattention-iswa.cpp ../src/llama-triattention.cpp)
target_include_directories(test-triattention-iswa PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_compile_features(test-triattention-iswa PRIVATE cxx_std_17)
target_link_libraries(test-triattention-iswa PRIVATE llama)
if (LLAMA_TESTS_INSTALL)
    install(TARGETS test-triattention-iswa RUNTIME)
endif()
add_test(NAME test-triattention-iswa WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-iswa>)
set_property(TEST test-triattention-iswa PROPERTY LABELS main)
add_executable(test-triattention-prune-budget test-triattention-prune-budget.cpp ../src/llama-triattention.cpp)
target_include_directories(test-triattention-prune-budget PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_compile_features(test-triattention-prune-budget PRIVATE cxx_std_17)
target_link_libraries(test-triattention-prune-budget PRIVATE llama)
if (LLAMA_TESTS_INSTALL)
    install(TARGETS test-triattention-prune-budget RUNTIME)
endif()
add_test(NAME test-triattention-prune-budget WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-prune-budget>)
set_property(TEST test-triattention-prune-budget PROPERTY LABELS main)
add_executable(test-triattention-modes test-triattention-modes.cpp ../src/llama-triattention.cpp)
target_include_directories(test-triattention-modes PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_compile_features(test-triattention-modes PRIVATE cxx_std_17)
target_link_libraries(test-triattention-modes PRIVATE llama)
if (LLAMA_TESTS_INSTALL)
    install(TARGETS test-triattention-modes RUNTIME)
endif()
add_test(NAME test-triattention-modes WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-modes>)
set_property(TEST test-triattention-modes PROPERTY LABELS main)

if (GGML_BITNET_I2_S)
    add_executable(test-bitnet-i2s-quant test-bitnet-i2s-quant.c
        ${LLAMA_VENDOR_BITNET_DIR}/src/ggml-bitnet-i2s-quants.c)
    target_include_directories(test-bitnet-i2s-quant PRIVATE
        ${PROJECT_SOURCE_DIR}/ggml/include
        ${PROJECT_SOURCE_DIR}/ggml/src
        ${LLAMA_VENDOR_BITNET_DIR}/include)
    target_compile_definitions(test-bitnet-i2s-quant PRIVATE GGML_BITNET_I2_S)
    target_link_libraries(test-bitnet-i2s-quant PRIVATE ggml)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS test-bitnet-i2s-quant RUNTIME)
    endif()
    add_test(NAME test-bitnet-i2s-quant WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-bitnet-i2s-quant>)
    set_property(TEST test-bitnet-i2s-quant PROPERTY LABELS bitnet)
endif()

if (GGML_CUDA)
    add_executable(test-triattention-gpu-parity test-triattention-gpu-parity.cpp ../src/llama-triattention.cpp)
    target_include_directories(test-triattention-gpu-parity PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include ${PROJECT_SOURCE_DIR}/ggml/src)
    target_compile_features(test-triattention-gpu-parity PRIVATE cxx_std_17)
    target_link_libraries(test-triattention-gpu-parity PRIVATE llama ggml-cuda)
    target_compile_definitions(test-triattention-gpu-parity PRIVATE GGML_USE_CUDA)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS test-triattention-gpu-parity RUNTIME)
    endif()
    add_test(NAME test-triattention-gpu-parity WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-gpu-parity>)
    set_property(TEST test-triattention-gpu-parity PROPERTY LABELS cuda)
    add_executable(test-triattention-host-kv-staging test-triattention-host-kv-staging.cpp ../src/llama-triattention.cpp)
    target_include_directories(test-triattention-host-kv-staging PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include ${PROJECT_SOURCE_DIR}/ggml/src)
    target_compile_features(test-triattention-host-kv-staging PRIVATE cxx_std_17)
    target_link_libraries(test-triattention-host-kv-staging PRIVATE llama ggml-cuda)
    target_compile_definitions(test-triattention-host-kv-staging PRIVATE GGML_USE_CUDA)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS test-triattention-host-kv-staging RUNTIME)
    endif()
    add_test(NAME test-triattention-host-kv-staging WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-host-kv-staging>)
    set_property(TEST test-triattention-host-kv-staging PROPERTY LABELS cuda)
    add_executable(test-triattention-rowbytes-multistream test-triattention-rowbytes-multistream.cpp)
    target_include_directories(test-triattention-rowbytes-multistream PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include ${PROJECT_SOURCE_DIR}/ggml/src)
    target_compile_features(test-triattention-rowbytes-multistream PRIVATE cxx_std_17)
    target_link_libraries(test-triattention-rowbytes-multistream PRIVATE llama ggml-cuda)
    target_compile_definitions(test-triattention-rowbytes-multistream PRIVATE GGML_USE_CUDA)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS test-triattention-rowbytes-multistream RUNTIME)
    endif()
    add_test(NAME test-triattention-rowbytes-multistream WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-rowbytes-multistream>)
    set_property(TEST test-triattention-rowbytes-multistream PROPERTY LABELS cuda)
    add_executable(test-triattention-gpu-fault-inject test-triattention-gpu-fault-inject.cpp)
    target_include_directories(test-triattention-gpu-fault-inject PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include ${PROJECT_SOURCE_DIR}/ggml/src)
    target_compile_features(test-triattention-gpu-fault-inject PRIVATE cxx_std_17)
    target_link_libraries(test-triattention-gpu-fault-inject PRIVATE llama ggml-cuda)
    target_compile_definitions(test-triattention-gpu-fault-inject PRIVATE GGML_USE_CUDA)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS test-triattention-gpu-fault-inject RUNTIME)
    endif()
    add_test(NAME test-triattention-gpu-fault-inject WORKING_DIRECTORY . COMMAND $<TARGET_FILE:test-triattention-gpu-fault-inject>)
    set_property(TEST test-triattention-gpu-fault-inject PROPERTY LABELS cuda)
endif()
llama_build_and_test(test-adaptive-dm.cpp)
llama_build_and_test(test-server-prompt-checkpoint.cpp)
target_include_directories(test-server-prompt-checkpoint PRIVATE ${PROJECT_SOURCE_DIR}/tools/server ${PROJECT_SOURCE_DIR}/tools/mtmd)
target_link_libraries(test-server-prompt-checkpoint PRIVATE server-context)
llama_build_and_test(test-server-context.cpp)
target_include_directories(test-server-context PRIVATE ${PROJECT_SOURCE_DIR}/tools/server ${PROJECT_SOURCE_DIR}/tools/mtmd)
target_link_libraries(test-server-context PRIVATE server-context)
llama_build_and_test(test-dflash-ring.cpp)
llama_build_and_test(test-cpu-out-prod.cpp)
llama_build_and_test(test-cpu-fattn-support.cpp)
llama_build_and_test(test-dflash-plumbing.cpp ARGS ${PROJECT_SOURCE_DIR})
target_include_directories(test-dflash-plumbing PRIVATE ${PROJECT_SOURCE_DIR}/src)
llama_build_and_test(test-mtmd-plumbing.cpp ARGS ${PROJECT_SOURCE_DIR})
llama_build_and_test(test-perplexity-plumbing.cpp ARGS ${PROJECT_SOURCE_DIR})
llama_build_and_test(test-cuda-fattn-route-policy.cpp ARGS ${PROJECT_SOURCE_DIR})
llama_build_and_test(test-cuda-fattn-vec-policy.cpp ARGS ${PROJECT_SOURCE_DIR})

if (NOT LLAMA_SANITIZE_ADDRESS AND NOT GGML_SCHED_NO_REALLOC)
  # TODO: repair known memory leaks
  llama_build_and_test(test-opt.cpp)
endif()
llama_build_and_test(test-gguf.cpp)
llama_build_and_test(test-backend-ops.cpp)

llama_build_and_test(test-model-load-cancel.cpp LABEL "model")
llama_build_and_test(test-autorelease.cpp       LABEL "model")
llama_build_and_test(test-backend-sampler.cpp   LABEL "model")

# Test for state restore with fragmented KV cache
# Requires a model, uses same args pattern as test-thread-safety
llama_build_and_test(test-state-restore-fragmented.cpp LABEL "model" ARGS -m "${MODEL_DEST}")
set_tests_properties(test-state-restore-fragmented PROPERTIES FIXTURES_REQUIRED test-download-model)

llama_build_and_test(test-recurrent-state-rollback.cpp LABEL "model" ARGS -m "${MODEL_DEST}")
set_tests_properties(test-recurrent-state-rollback PROPERTIES FIXTURES_REQUIRED test-download-model)

# Test state save/load functionality
llama_build_and_test(test-save-load-state.cpp LABEL "model" ARGS -m "${MODEL_DEST}")
set_tests_properties(test-save-load-state PROPERTIES FIXTURES_REQUIRED test-download-model)

if (NOT GGML_BACKEND_DL)
    # these tests use the backends directly and cannot be built with dynamic loading
    llama_build_and_test(test-barrier.cpp)
    llama_build_and_test(test-quantize-fns.cpp)
    llama_build_and_test(test-quantize-perf.cpp)
    llama_build_and_test(test-turbo-quant.c)
    llama_build_and_test(test-rope.cpp)
    llama_build_and_test(test-col2im-1d.cpp)
endif()

# libmtmd
set(LLAMA_TEST_NAME test-mtmd-c-api)
llama_build_and_test(test-mtmd-c-api.c)
target_link_libraries(${LLAMA_TEST_NAME} PRIVATE mtmd)
unset(LLAMA_TEST_NAME)

# GGUF model data fetcher library for tests that need real model metadata
# Only compile when cpp-httplib has SSL support (CPPHTTPLIB_OPENSSL_SUPPORT)
if (TARGET cpp-httplib)
    get_target_property(_cpp_httplib_defs cpp-httplib INTERFACE_COMPILE_DEFINITIONS)
    if (_cpp_httplib_defs MATCHES "CPPHTTPLIB_OPENSSL_SUPPORT")
        add_library(gguf-model-data STATIC gguf-model-data.cpp)
        target_link_libraries(gguf-model-data PRIVATE llama-common cpp-httplib)
        target_include_directories(gguf-model-data PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

        add_executable(test-gguf-model-data test-gguf-model-data.cpp)
        target_link_libraries(test-gguf-model-data PRIVATE gguf-model-data llama-common)
        llama_test(test-gguf-model-data LABEL "model")

        # test-quant-type-selection requires gguf-model-data for remote model metadata
        llama_build_and_test(test-quant-type-selection.cpp LABEL "model")
        target_link_libraries(test-quant-type-selection PRIVATE gguf-model-data)
        target_compile_definitions(test-quant-type-selection PRIVATE
            SNAPSHOT_DIR="${CMAKE_CURRENT_SOURCE_DIR}/snapshots")
    endif()
endif()

# dummy executable - not installed
get_filename_component(TEST_TARGET test-c.c NAME_WE)
add_executable(${TEST_TARGET} test-c.c)
target_link_libraries(${TEST_TARGET} PRIVATE llama)

llama_build_and_test(test-alloc.cpp)
target_include_directories(test-alloc PRIVATE ${PROJECT_SOURCE_DIR}/ggml/src)

# op coverage test: catches enum/name/symbol table drift before release
add_executable(test-ggml-op-coverage test-ggml-op-coverage.cpp)
target_include_directories(test-ggml-op-coverage PRIVATE ${PROJECT_SOURCE_DIR}/ggml/include)
target_link_libraries(test-ggml-op-coverage PRIVATE ggml)
add_test(NAME test-ggml-op-coverage COMMAND test-ggml-op-coverage)

llama_build(export-graph-ops.cpp)
target_include_directories(export-graph-ops PRIVATE ${PROJECT_SOURCE_DIR}/ggml/src)
if (TARGET gguf-model-data)
    target_link_libraries(export-graph-ops PRIVATE gguf-model-data)
    target_compile_definitions(export-graph-ops PRIVATE LLAMA_HF_FETCH)
endif()
