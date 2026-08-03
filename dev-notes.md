# Development Notes

## Cline Terminal Output Capture Issue

### Problem
Some CLI commands (e.g., `git status --short`) return the message:
> The command's output could not be captured due to some technical issue, however it has been executed successfully.

The commands **do execute correctly** (confirmed by exit codes, file changes, and subsequent commands like `git log`), but the inline output stream is not captured for display.

### Workaround
Append `2>&1 | tee /tmp/out.txt` to redirect both stdout and stderr to a file that can be read separately:

```bash
git status --short 2>&1 | tee /tmp/out.txt && echo "EXIT:$?"
```

Then read the file with `cat /tmp/out.txt` if the inline capture fails.

Alternatively, use commands that tend to stream reliably (e.g., `git log --oneline -3`, commands with visible progress bars like `git push`) to verify state indirectly.