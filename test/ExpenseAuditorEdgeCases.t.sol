// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../ExpenseAuditor.sol";

/// Extra edge cases from Ritual's "six builder best practices for async results":
/// parse model output defensively, keep storage bounded, and validate inputs.
/// Complements ExpenseAuditor.t.sol (empty path / hasError / expiry).
contract ExpenseAuditorEdgeCasesTest is Test {
    ExpenseAuditor auditor;
    address constant LLM = address(0x0802);
    address executor = makeAddr("executor");

    function setUp() public {
        auditor = new ExpenseAuditor();
        vm.etch(LLM, hex"00");
    }

    // ------------------------------------------------------------ helpers

    function _answer(string memory content) internal pure returns (bytes memory) {
        bytes memory message = abi.encode("assistant", content, "", uint256(0), new bytes[](0));
        bytes[] memory choices = new bytes[](1);
        choices[0] = abi.encode(uint256(0), "stop", message);
        bytes memory completion = abi.encode(
            "id", "chat.completion", uint256(1), "zai-org/GLM-4.7-FP8", "", "auto", uint256(1), choices, bytes("")
        );
        bytes memory actual = abi.encode(false, completion, bytes(""), "", ExpenseAuditor.StorageRef("", "", ""));
        return abi.encode(bytes("input"), actual);
    }

    function _mockAnswer(string memory content) internal {
        vm.mockCall(LLM, bytes(""), _answer(content));
    }

    function _submit() internal returns (ExpenseAuditor.Expense memory) {
        uint256 id = auditor.submitExpense(executor, 499_900, "Meals", "Team dinner");
        return auditor.getExpense(id);
    }

    // ------------------------------------------------------------ defensive parsing

    /// A verdict inside the <think> block must not count; the last verdict after it wins.
    function test_VerdictInsideThinkBlock_IsIgnored() public {
        _mockAnswer("<think>Maybe VERDICT: NORMAL?</think>Round amount, vague purpose.\nVERDICT: SUSPICIOUS");
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(e.status, auditor.STATUS_SUSPICIOUS());
        assertEq(e.aiAnswer, "Round amount, vague purpose.\nVERDICT: SUSPICIOUS");
    }

    /// Markdown with the colon inside the bold marker: "**VERDICT:** NORMAL".
    function test_MarkdownVerdict_BoldLabelOnly() public {
        _mockAnswer("Documented client meeting, reasonable amount.\n**VERDICT:** NORMAL");
        assertEq(_submit().status, auditor.STATUS_NORMAL());
    }

    /// Lower-case or unknown verdict words are treated as unclear, not guessed.
    function test_UnknownVerdictWord_IsUnclear() public {
        _mockAnswer("Hard to say.\nVERDICT: maybe");
        assertEq(_submit().status, auditor.STATUS_UNCLEAR());
    }

    // ------------------------------------------------------------ bounded storage

    /// Long answers are truncated to 400 bytes in storage; verdict still read from the full text.
    function test_LongAnswer_TruncatedButVerdictKept() public {
        bytes memory longText = new bytes(1000);
        for (uint256 i = 0; i < longText.length; i++) longText[i] = "a";
        _mockAnswer(string.concat(string(longText), "\nVERDICT: NORMAL"));
        ExpenseAuditor.Expense memory e = _submit();
        assertEq(bytes(e.aiAnswer).length, 400);
        assertEq(e.status, auditor.STATUS_NORMAL());
    }

    // ------------------------------------------------------------ input validation

    function test_RevertsOnEmptyCategory() public {
        _mockAnswer("VERDICT: NORMAL");
        vm.expectRevert("bad category");
        auditor.submitExpense(executor, 100, "", "x");
    }

    function test_RevertsOnTooLongDescription() public {
        _mockAnswer("VERDICT: NORMAL");
        bytes memory tooLong = new bytes(501);
        for (uint256 i = 0; i < tooLong.length; i++) tooLong[i] = "x";
        vm.expectRevert("bad description");
        auditor.submitExpense(executor, 100, "Travel", string(tooLong));
    }

    /// Quotes and backslashes are escaped in the prompt and stored verbatim.
    function test_SpecialCharactersInDescription() public {
        _mockAnswer("VERDICT: NORMAL");
        string memory desc = "Hotel \"Grand\" \\ 3 nights";
        uint256 id = auditor.submitExpense(executor, 12_345, "Travel", desc);
        assertEq(auditor.getExpense(id).description, desc);
        assertEq(auditor.getExpense(id).status, auditor.STATUS_NORMAL());
    }
}
