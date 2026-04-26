// Add this to your H200 HTML page (in the <script> section)

// ===== SIMPLIFIED DIFF APPLIER FOR BASH SCRIPTS =====
class BashDiffApplier {
  /**
   * Apply a unified diff to bash script content
   * Handles line number shifts correctly
   */
  applyDiff(originalContent, diffText) {
    const originalLines = originalContent.split("\n");
    const diffLines = diffText.split("\n");
    let newLines = [...originalLines];
    let offset = 0;

    // Parse each hunk
    for (let i = 0; i < diffLines.length; i++) {
      const line = diffLines[i];

      // Look for hunk header: @@ -start,count +start,count @@
      const hunkMatch = line.match(
        /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
      );

      if (hunkMatch) {
        const oldStart = parseInt(hunkMatch[1]) - 1; // 0-indexed
        const oldCount = parseInt(hunkMatch[2]) || 1;
        const newStart = parseInt(hunkMatch[3]) - 1;
        const newCount = parseInt(hunkMatch[4]) || 1;

        // Collect hunk lines
        const hunkLines = [];
        i++;
        while (i < diffLines.length && !diffLines[i].startsWith("@@")) {
          hunkLines.push(diffLines[i]);
          i++;
        }
        i--; // Step back so loop doesn't skip next hunk

        // Apply the hunk with offset
        const result = this.applyHunk(
          newLines,
          hunkLines,
          oldStart + offset,
          oldCount
        );
        newLines = result.lines;
        offset = result.newOffset;
      }
    }

    return newLines.join("\n");
  }

  /**
   * Apply a single hunk with offset tracking
   */
  applyHunk(lines, hunkLines, startLine, expectedCount) {
    const result = [];
    let lineIdx = 0;
    let hunkIdx = 0;
    let offset = 0;

    // Copy lines before the hunk
    while (lineIdx < startLine && lineIdx < lines.length) {
      result.push(lines[lineIdx]);
      lineIdx++;
    }

    // Track if we've processed the context
    let contextMatched = true;

    // Process the hunk
    while (hunkIdx < hunkLines.length) {
      const hunkLine = hunkLines[hunkIdx];

      if (hunkLine.startsWith(" ")) {
        // Context line - should match
        const context = hunkLine.substring(1);
        if (lineIdx < lines.length && lines[lineIdx] === context) {
          result.push(lines[lineIdx]);
          lineIdx++;
        } else {
          // Context mismatch - still add it
          result.push(context);
        }
        hunkIdx++;
      } else if (hunkLine.startsWith("-")) {
        // Remove line - skip it in original
        const removed = hunkLine.substring(1);
        if (lineIdx < lines.length && lines[lineIdx] === removed) {
          lineIdx++;
        }
        hunkIdx++;
        offset--; // Removing a line shifts everything left
      } else if (hunkLine.startsWith("+")) {
        // Add line
        const added = hunkLine.substring(1);
        result.push(added);
        hunkIdx++;
        offset++; // Adding a line shifts everything right
      }
    }

    // Copy remaining lines after the hunk
    while (lineIdx < lines.length) {
      result.push(lines[lineIdx]);
      lineIdx++;
    }

    return {
      lines: result,
      newOffset: offset,
    };
  }

  /**
   * Extract diff from AI response
   */
  extractDiff(aiResponse) {
    // Look for diff blocks in markdown
    const diffRegex = /```(?:diff)?\s*\n([\s\S]*?)\n```/g;
    let match;
    let lastDiff = null;

    while ((match = diffRegex.exec(aiResponse)) !== null) {
      const diff = match[1];
      if (
        diff.includes("@@") &&
        (diff.includes("---") || diff.includes("+++"))
      ) {
        lastDiff = diff;
      }
    }

    // If no markdown diff, look for raw unified diff
    if (!lastDiff) {
      const rawDiffRegex = /(--- .*?\n\+\+\+ .*?\n@@ .*?@@[\s\S]*?)(?=\n\n|$)/g;
      match = rawDiffRegex.exec(aiResponse);
      if (match) {
        lastDiff = match[1];
      }
    }

    return lastDiff ? this.cleanDiff(lastDiff) : null;
  }

  /**
   * Clean up a diff string
   */
  cleanDiff(diff) {
    return diff
      .replace(/^\s+|\s+$/g, "") // Trim
      .split("\n")
      .map((line) => line.replace(/\r$/, ""))
      .join("\n");
  }

  /**
   * Preview changes
   */
  previewDiff(original, diff) {
    const originalLines = original.split("\n");
    const newContent = this.applyDiff(original, diff);
    const newLines = newContent.split("\n");

    // Find changed lines
    const changes = [];
    for (let i = 0; i < Math.max(originalLines.length, newLines.length); i++) {
      if (originalLines[i] !== newLines[i]) {
        changes.push({
          line: i + 1,
          original: originalLines[i] || "(end)",
          new: newLines[i] || "(end)",
        });
      }
    }

    return {
      originalLines,
      newLines,
      changes,
      totalChanges: changes.length,
    };
  }

  /**
   * Validate diff format
   */
  validateDiff(diff) {
    const lines = diff.split("\n");
    const errors = [];
    const warnings = [];

    if (lines.length === 0) {
      errors.push("Diff is empty");
      return { isValid: false, errors, warnings };
    }

    // Check for headers
    const hasHeader =
      lines.some((l) => l.startsWith("--- ")) &&
      lines.some((l) => l.startsWith("+++ "));
    if (!hasHeader) {
      warnings.push("Missing ---/+++ headers (might still work)");
    }

    // Check for hunks
    let hasHunk = false;
    lines.forEach((line, i) => {
      if (line.startsWith("@@")) {
        hasHunk = true;
        const match = line.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
        if (!match) {
          errors.push(`Invalid hunk header at line ${i + 1}: ${line}`);
        }
      }
    });

    if (!hasHunk) {
      errors.push("No valid diff hunks found");
    }

    return {
      isValid: errors.length === 0,
      errors,
      warnings,
    };
  }
}

// Initialize the diff applier
const bashDiffApplier = new BashDiffApplier();

// Add these functions to your existing script
function applyAIDiffToScript(diffText) {
  if (!window.scriptRaw) {
    alert("No script loaded to apply diff to");
    return;
  }

  // Validate first
  const validation = bashDiffApplier.validateDiff(diffText);
  if (!validation.isValid) {
    alert("Invalid diff:\n" + validation.errors.join("\n"));
    return;
  }

  // Preview changes
  const preview = bashDiffApplier.previewDiff(window.scriptRaw, diffText);

  // Show preview in a modal/console
  console.log("Changes to apply:", preview.changes);

  // Ask for confirmation
  if (confirm(`Apply ${preview.totalChanges} changes to the script?`)) {
    const newScript = bashDiffApplier.applyDiff(window.scriptRaw, diffText);

    // Update the displayed script
    const scriptContent = document.getElementById("scriptContent");
    const highlighted = highlightBash(newScript);
    scriptContent.innerHTML = `<pre style="margin:0; padding:0; font-family:inherit;">${highlighted}</pre>`;

    // Update stored raw script
    window.scriptRaw = newScript;

    // Optional: Upload to CDN or save
    uploadModifiedScript(newScript);

    alert("✅ Diff applied successfully!");
  }
}

function uploadModifiedScript(scriptContent) {
  // In a real implementation, you'd upload this to your CDN/backend
  // For now, just log it
  console.log("Script updated, ready for upload");

  // You could show a "curl" command to run the updated script
  const curlCommand = `curl -s https://your-cdn.com/updated-script.sh | bash`;

  if (term) {
    term.writeln("\r\n\x1b[1;33m📤 Script updated! Run with:\x1b[0m");
    term.writeln(`\x1b[1;32m${curlCommand}\x1b[0m`);
  }
}

// Add a button to apply last AI diff
function addDiffControls() {
  const scriptPanel = document.querySelector(".script-panel .panel-header");
  if (scriptPanel) {
    const applyDiffBtn = document.createElement("button");
    applyDiffBtn.className = "copy-btn";
    applyDiffBtn.innerHTML = "🔧 Apply AI Diff";
    applyDiffBtn.onclick = () => {
      const diff = prompt("Paste the AI-generated diff:");
      if (diff) {
        applyAIDiffToScript(diff);
      }
    };
    scriptPanel.appendChild(applyDiffBtn);
  }
}

// Call this after page load
document.addEventListener("DOMContentLoaded", () => {
  addDiffControls();
});
