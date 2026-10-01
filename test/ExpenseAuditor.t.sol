// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ExpenseAuditor.sol";

/// "Test the empty path" — Ritual DevRel homework (Oct 15).
/// The LLM precompile (0x0802) is mocked so every way an answer can fail to
/// arrive (nothing, empty, error, expired, blank) is exercised without a chain.
contract ExpenseAuditorTest is Test {
    ExpenseAuditor auditor;
    address constant LLM = address(0x0802);
    address executor = makeAddr("executor");

    function setUp() public {
        auditor = new ExpenseAuditor();
        vm.etch(LLM, hex"00"); // give the precompile address code so the mock is always hit
    }

    // ------------------------------------------------------------ helpers

    /// Short-running async envelope: (bytes simmedInput, bytes actualOutput)
    function _envelope(bytes memory actualOutput) internal pure returns (bytes memory) {
        return abi.encode(bytes("input"), actualOutput);
    }

    function _llmOutput(bool hasError, bytes memory completion, string memory err)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(hasError, completion, bytes(""), err, ExpenseAuditor.StorageRef("", "", ""));
    }

    function _completion(string memory content) internal pure returns (bytes memory) {
        bytes memory message = abi.encode("assistant", content, "", uint256(0), new bytes[](0));
        bytes[] memory choices = new bytes[](1);
        choices[0] = abi.encode(uint256(0), "stop", message);
        return abi.encode("id", "chat.completion", uint256(1), "zai-org/GLM-4.7-FP8", "", "auto", uint256(1), choices, bytes(""));
    }

    function _noChoices() internal pure returns (bytes memory) {
        return abi.encode("id", "chat.completion", uint256(1), "zai-org/GLM-4.7-FP8", "", "auto", uint256(0), new bytes[](0), bytes(""));
    }

    function _mock(bytes memory ret) internal {
        vm.mockCall(LLM, bytes(""), ret);
    }

    function _submit() internal returns (ExpenseAuditor.Expense memory) {
        uint256 id = auditor.submitExpense(executor, 49_900, "Travel", "Taxi to client meeting");
        return auditor.getExpense(id);
    }

    // ------------------------------------------------------------ empty path

    function test_EmptyResult_RecordedAsAiError() public {
        _mock("");
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_AI_ERROR());
        assertEq(e.aiAnswer, "no result");
    }

    function test_LateResult_EmptyOutput_RecordedAsAiError() public {
        _mock(_envelope(""));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_AI_ERROR());
        assertEq(e.aiAnswer, "empty output");
    }

    function test_Expired_RecordedAsAiError() public {
        string memory err = "Request expired: emission block 1400 > (commit block 1000 + TTL 300)";
        _mock(_envelope(_llmOutput(true, "", err)));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_AI_ERROR());
        assertEq(e.aiAnswer, err);
    }

    function test_ExecutorError_RecordedAsAiError() public {
        _mock(_envelope(_llmOutput(true, "", "executor unavailable")));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_AI_ERROR());
    }

    /// Model replied, but with zero choices: there is no answer to audit.
    function test_NoChoices_RecordedAsAiError() public {
        _mock(_envelope(_llmOutput(false, _noChoices(), "")));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_AI_ERROR());
        assertEq(e.aiAnswer, "empty answer");
    }

    /// Model only "thought" and returned nothing after </think>.
    function test_BlankAnswerAfterThinking_RecordedAsAiError() public {
        _mock(_envelope(_llmOutput(false, _completion("<think>let me check...</think>  \n "), "")));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_AI_ERROR());
        assertEq(e.aiAnswer, "empty answer");
    }

    function test_PrecompileFailure_Reverts() public {
        vm.mockCallRevert(LLM, bytes(""), "boom");
        vm.expectRevert("LLM precompile call failed");
        auditor.submitExpense(executor, 100, "Meals", "Lunch");
    }

    // ------------------------------------------------------------ happy path

    function test_NormalVerdict() public {
        _mock(_envelope(_llmOutput(false, _completion("<think>fine</think>Reasonable taxi fare.\nVERDICT: NORMAL"), "")));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_NORMAL());
    }

    function test_SuspiciousVerdict_Bold() public {
        _mock(_envelope(_llmOutput(false, _completion("Round number, vague purpose.\n**VERDICT: SUSPICIOUS**"), "")));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_SUSPICIOUS());
    }

    function test_NoVerdictLine_Unclear() public {
        _mock(_envelope(_llmOutput(false, _completion("Looks okay to me."), "")));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_UNCLEAR());
    }
}
