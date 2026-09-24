// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ExpenseAuditor — AI forensic-accounting checks on Ritual Chain
/// @notice Anyone submits an expense; Ritual's on-chain LLM (precompile 0x0802)
///         reviews it for red flags, and the verdict is kept in a public audit log.
contract ExpenseAuditor {
    address public constant LLM_PRECOMPILE = 0x0000000000000000000000000000000000000802;
    string public constant MODEL = "zai-org/GLM-4.7-FP8";

    uint8 public constant STATUS_UNCLEAR = 0;    // AI answered but gave no clear verdict
    uint8 public constant STATUS_NORMAL = 1;
    uint8 public constant STATUS_SUSPICIOUS = 2;
    uint8 public constant STATUS_AI_ERROR = 3;   // executor / model returned an error

    struct Expense {
        address submitter;
        uint256 amountCents;
        string category;
        string description;
        uint64 timestamp;
        uint8 status;
        string aiAnswer;      // AI's short explanation (first 400 bytes)
    }

    struct StorageRef {
        string platform;
        string path;
        string keyRef;
    }

    // Mirrors the 30-field LLM request tuple from the Ritual precompile ABI.
    struct LLMRequest {
        address executor;
        bytes[] encryptedSecrets;
        uint256 ttl;
        bytes[] secretSignatures;
        bytes userPublicKey;
        string messagesJson;
        string model;
        int256 frequencyPenalty;
        string logitBiasJson;
        bool logprobs;
        int256 maxCompletionTokens;
        string metadataJson;
        string modalitiesJson;
        uint256 n;
        bool parallelToolCalls;
        int256 presencePenalty;
        string reasoningEffort;
        bytes responseFormatData;
        int256 seed;
        string serviceTier;
        string stopJson;
        bool stream;
        int256 temperature;
        bytes toolChoiceData;
        bytes toolsData;
        int256 topLogprobs;
        int256 topP;
        string user;
        bool piiEnabled;
        StorageRef convoHistory;
    }

    Expense[] private _expenses;

    event ExpenseAudited(
        uint256 indexed id,
        address indexed submitter,
        uint8 status,
        string aiAnswer
    );

    string private constant SYSTEM_PROMPT =
        "You are a forensic accounting auditor. Review one business expense for red flags: "
        "amount unusual for the category, vague or missing business purpose, personal items, "
        "suspicious round numbers, possible split purchases, or duplicate-looking entries. "
        "Answer in at most two short sentences, then finish with exactly one final line: "
        "VERDICT: NORMAL or VERDICT: SUSPICIOUS";

    // ---------------------------------------------------------------- write

    /// @param executor   TEE executor address with LLM capability (from TEEServiceRegistry)
    /// @param amountCents expense amount in cents (e.g. 12345 = 123.45)
    function submitExpense(
        address executor,
        uint256 amountCents,
        string calldata category,
        string calldata description
    ) external returns (uint256 id) {
        require(bytes(category).length > 0 && bytes(category).length <= 64, "bad category");
        require(bytes(description).length > 0 && bytes(description).length <= 500, "bad description");

        bytes memory input = _buildRequest(executor, amountCents, category, description);

        (bool ok, bytes memory result) = LLM_PRECOMPILE.call(input);
        require(ok, "LLM precompile call failed");

        (uint8 status, string memory answer) = _parseResult(result);

        id = _expenses.length;
        _expenses.push(Expense({
            submitter: msg.sender,
            amountCents: amountCents,
            category: category,
            description: description,
            timestamp: uint64(block.timestamp),
            status: status,
            aiAnswer: _truncate(bytes(answer), 400)
        }));

        emit ExpenseAudited(id, msg.sender, status, answer);
    }

    // ---------------------------------------------------------------- read

    function expenseCount() external view returns (uint256) {
        return _expenses.length;
    }

    function getExpense(uint256 id) external view returns (Expense memory) {
        return _expenses[id];
    }

    // ---------------------------------------------------------------- internals

    function _buildRequest(
        address executor,
        uint256 amountCents,
        string calldata category,
        string calldata description
    ) internal pure returns (bytes memory input) {
        string memory userMsg = string.concat(
            "Expense amount: ", _formatCents(amountCents),
            ". Category: ", _escape(bytes(category)),
            ". Description: ", _escape(bytes(description)), "."
        );
        string memory messages = string.concat(
            '[{"role":"system","content":"', SYSTEM_PROMPT,
            '"},{"role":"user","content":"', userMsg, '"}]'
        );

        LLMRequest memory r;
        r.executor = executor;
        r.encryptedSecrets = new bytes[](0);
        r.ttl = 300;
        r.secretSignatures = new bytes[](0);
        r.userPublicKey = "";
        r.messagesJson = messages;
        r.model = MODEL;
        r.frequencyPenalty = 0;
        r.logitBiasJson = "";
        r.logprobs = false;
        r.maxCompletionTokens = 4096;
        r.metadataJson = "";
        r.modalitiesJson = "";
        r.n = 1;
        r.parallelToolCalls = true;
        r.presencePenalty = 0;
        r.reasoningEffort = "low";
        r.responseFormatData = "";
        r.seed = -1;
        r.serviceTier = "auto";
        r.stopJson = "";
        r.stream = false;
        r.temperature = 200;          // 0.2 — steady, audit-style answers
        r.toolChoiceData = "";
        r.toolsData = "";
        r.topLogprobs = -1;
        r.topP = 1000;
        r.user = "";
        r.piiEnabled = false;
        r.convoHistory = StorageRef("", "", "");   // empty ref = no stored history

        // abi.encode(struct) = [32-byte offset][tuple encoding].
        // The precompile expects the flat 30-parameter encoding, which is exactly
        // the tuple encoding, so drop the leading offset word.
        input = abi.encode(r);
        assembly {
            let len := mload(input)
            input := add(input, 32)
            mstore(input, sub(len, 32))
        }
    }

    function _parseResult(bytes memory result)
        internal
        pure
        returns (uint8 status, string memory answer)
    {
        if (result.length == 0) return (STATUS_AI_ERROR, "no result");

        // Short-running async envelope: (bytes simmedInput, bytes actualOutput)
        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));
        if (actualOutput.length == 0) return (STATUS_AI_ERROR, "empty output");

        (bool hasError, bytes memory completionData, , string memory errorMessage, ) =
            abi.decode(actualOutput, (bool, bytes, bytes, string, StorageRef));
        if (hasError) return (STATUS_AI_ERROR, errorMessage);

        string memory content = _extractContent(completionData);
        bytes memory finalText = _afterLast(bytes(content), bytes("</think>"));
        answer = string(finalText);
        status = _verdict(finalText);
    }

    function _extractContent(bytes memory completionData) internal pure returns (string memory) {
        (, , , , , , uint256 choicesCount, bytes[] memory choicesData, ) = abi.decode(
            completionData,
            (string, string, uint256, string, string, string, uint256, bytes[], bytes)
        );
        if (choicesCount == 0 || choicesData.length == 0) return "";
        (, , bytes memory messageData) = abi.decode(choicesData[0], (uint256, string, bytes));
        (, string memory content, , , ) =
            abi.decode(messageData, (string, string, string, uint256, bytes[]));
        return content;
    }

    function _verdict(bytes memory text) internal pure returns (uint8) {
        bytes memory tail = _afterLast(text, bytes("VERDICT:"));
        if (tail.length == text.length) return STATUS_UNCLEAR; // marker not found
        uint256 i = 0;
        while (i < tail.length && (tail[i] == " " || tail[i] == "*")) i++;
        if (_startsWith(tail, i, "SUSPICIOUS")) return STATUS_SUSPICIOUS;
        if (_startsWith(tail, i, "NORMAL")) return STATUS_NORMAL;
        return STATUS_UNCLEAR;
    }

    /// Returns the bytes after the LAST occurrence of `marker`, or the whole text if absent.
    function _afterLast(bytes memory text, bytes memory marker) internal pure returns (bytes memory) {
        if (text.length < marker.length) return text;
        uint256 start = 0;
        bool found = false;
        for (uint256 i = text.length - marker.length + 1; i > 0; i--) {
            if (_startsWith(text, i - 1, string(marker))) {
                start = i - 1 + marker.length;
                found = true;
                break;
            }
        }
        if (!found) return text;
        bytes memory out = new bytes(text.length - start);
        for (uint256 j = 0; j < out.length; j++) out[j] = text[start + j];
        return out;
    }

    function _startsWith(bytes memory text, uint256 at, string memory word) internal pure returns (bool) {
        bytes memory w = bytes(word);
        if (at + w.length > text.length) return false;
        for (uint256 k = 0; k < w.length; k++) {
            if (text[at + k] != w[k]) return false;
        }
        return true;
    }

    function _truncate(bytes memory s, uint256 max) internal pure returns (string memory) {
        if (s.length <= max) return string(s);
        bytes memory out = new bytes(max);
        for (uint256 i = 0; i < max; i++) out[i] = s[i];
        return string(out);
    }

    /// JSON-escape user text so it can't break the prompt structure.
    function _escape(bytes memory s) internal pure returns (string memory) {
        bytes memory out = new bytes(s.length * 2);
        uint256 n = 0;
        for (uint256 i = 0; i < s.length; i++) {
            bytes1 c = s[i];
            if (c == '"' || c == "\\") {
                out[n++] = "\\";
                out[n++] = c;
            } else if (uint8(c) < 0x20) {
                out[n++] = " ";
            } else {
                out[n++] = c;
            }
        }
        assembly { mstore(out, n) }
        return string(out);
    }

    function _formatCents(uint256 cents) internal pure returns (string memory) {
        uint256 frac = cents % 100;
        return string.concat(
            _toString(cents / 100), ".", frac < 10 ? "0" : "", _toString(frac)
        );
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory b = new bytes(len);
        while (v != 0) {
            b[--len] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }
}
