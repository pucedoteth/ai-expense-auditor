// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ExpenseAuditor} from "../ExpenseAuditor.sol";

/// Minimal Foundry cheatcode interface (no forge-std dependency needed).
interface Vm {
    function mockCall(address callee, bytes calldata data, bytes calldata returnData) external;
    function clearMockedCalls() external;
    function etch(address target, bytes calldata code) external;
    function expectRevert(bytes calldata revertData) external;
}

/// Edge-case tests for the Ritual LLM precompile integration, following
/// Ritual's builder best practices: mock an empty result, an error response,
/// and malformed output with vm.mockCall, then run one live transaction for real.
contract ExpenseAuditorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant LLM = 0x0000000000000000000000000000000000000802;
    address constant EXECUTOR = address(0xE1);

    struct StorageRef { string platform; string path; string keyRef; }

    ExpenseAuditor auditor;

    function setUp() public {
        auditor = new ExpenseAuditor();
        vm.etch(LLM, hex"00"); // give the precompile address code so mocks apply cleanly
    }

    // ------------------------------------------------------------ helpers

    /// Builds the async envelope (simmedInput, actualOutput) the precompile returns.
    function _envelope(bool hasError, string memory content, string memory errorMessage)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory completion = "";
        if (!hasError) {
            bytes memory messageData = abi.encode("assistant", content, "", uint256(0), new bytes[](0));
            bytes[] memory choices = new bytes[](1);
            choices[0] = abi.encode(uint256(0), "stop", messageData);
            completion = abi.encode(
                "chatcmpl-test", "chat.completion", uint256(0), "zai-org/GLM-4.7-FP8",
                "", "auto", uint256(1), choices, abi.encode(uint256(50), uint256(20), uint256(70))
            );
        }
        bytes memory actual = abi.encode(hasError, completion, bytes(""), errorMessage, StorageRef("", "", ""));
        return abi.encode(bytes(""), actual);
    }

    function _mock(bytes memory ret) internal {
        vm.clearMockedCalls();
        vm.mockCall(LLM, bytes(""), ret); // empty calldata = match any request
    }

    function _submit() internal returns (ExpenseAuditor.Expense memory) {
        uint256 id = auditor.submitExpense(EXECUTOR, 499900, "Meals", "Team dinner");
        return auditor.getExpense(id);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _contains(string memory text, string memory word) internal pure returns (bool) {
        bytes memory t = bytes(text);
        bytes memory w = bytes(word);
        if (w.length > t.length) return false;
        for (uint256 i = 0; i + w.length <= t.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < w.length; j++) {
                if (t[i + j] != w[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    // ------------------------------------------------------------ tests

    /// Happy path: reasoning block is stripped; the LAST verdict line wins.
    function test_SuspiciousVerdict_IgnoresThinkBlock() public {
        _mock(_envelope(false,
            "<think>Maybe VERDICT: NORMAL?</think>Round amount and vague purpose for a meal.\nVERDICT: SUSPICIOUS",
            ""));
        ExpenseAuditor.Expense memory e = _submit();
        require(e.status == auditor.STATUS_SUSPICIOUS(), "expected SUSPICIOUS");
        require(!_contains(e.aiAnswer, "<think>"), "think block should be removed");
        require(_contains(e.aiAnswer, "Round amount"), "explanation should be stored");
        require(e.amountCents == 499900 && e.submitter == address(this), "record fields wrong");
    }

    /// Markdown-styled verdicts (**VERDICT:** NORMAL) still parse.
    function test_NormalVerdict_WithMarkdown() public {
        _mock(_envelope(false, "Documented client meeting, reasonable amount.\n**VERDICT:** NORMAL", ""));
        require(_submit().status == auditor.STATUS_NORMAL(), "expected NORMAL");
    }

    /// Best practice: check hasError before reading completionData.
    function test_HasError_IsRecordedNotReverted() public {
        _mock(_envelope(true, "", "HTTP request failed with status 400: context length exceeded"));
        ExpenseAuditor.Expense memory e = _submit();
        require(e.status == auditor.STATUS_AI_ERROR(), "expected AI_ERROR");
        require(_contains(e.aiAnswer, "context length"), "error message should be stored");
    }

    /// Best practice: an empty result (e.g. the eth_call / simulation phase) must not revert.
    function test_EmptyResult_DoesNotRevert() public {
        _mock(bytes(""));
        ExpenseAuditor.Expense memory e = _submit();
        require(e.status == auditor.STATUS_AI_ERROR(), "expected AI_ERROR");
        require(_eq(e.aiAnswer, "no result"), "expected 'no result'");
    }

    /// Envelope present but no settled output yet (expired / not delivered).
    function test_EmptyActualOutput_DoesNotRevert() public {
        _mock(abi.encode(bytes(""), bytes("")));
        ExpenseAuditor.Expense memory e = _submit();
        require(e.status == auditor.STATUS_AI_ERROR(), "expected AI_ERROR");
        require(_eq(e.aiAnswer, "empty output"), "expected 'empty output'");
    }

    /// Best practice: parse defensively — model ignored the format instructions.
    function test_MissingVerdict_IsUnclear() public {
        _mock(_envelope(false, "I am not sure about this expense.", ""));
        require(_submit().status == auditor.STATUS_UNCLEAR(), "expected UNCLEAR");
    }

    /// Long AI answers are truncated in storage (gas safety).
    function test_LongAnswer_IsTruncated() public {
        bytes memory longText = new bytes(1000);
        for (uint256 i = 0; i < longText.length; i++) longText[i] = "a";
        _mock(_envelope(false, string.concat(string(longText), "\nVERDICT: NORMAL"), ""));
        ExpenseAuditor.Expense memory e = _submit();
        require(bytes(e.aiAnswer).length == 400, "answer should be truncated to 400 bytes");
        require(e.status == auditor.STATUS_NORMAL(), "verdict still read from full text");
    }

    /// Input validation.
    function test_RevertsOnEmptyCategory() public {
        _mock(_envelope(false, "VERDICT: NORMAL", ""));
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "bad category"));
        auditor.submitExpense(EXECUTOR, 100, "", "x");
    }

    /// Quotes and backslashes in user text are escaped and don't break the request.
    function test_SpecialCharactersInDescription() public {
        _mock(_envelope(false, "VERDICT: NORMAL", ""));
        uint256 id = auditor.submitExpense(EXECUTOR, 12345, "Travel", "Hotel \"Grand\" \\ 3 nights");
        require(_eq(auditor.getExpense(id).description, "Hotel \"Grand\" \\ 3 nights"), "description stored verbatim");
        require(auditor.expenseCount() == 1, "count should be 1");
    }
}
