---
name: no-replying-to-humans-on-users-behalf
description: "Never post or resolve GitHub review replies/comments to human reviewers without the user's explicit go-ahead"
condition: ["pulls/\\d+/comments/\\d+/replies", "resolveReviewThread", "gh\\s+(pr|issue)\\s+comment\\b", "gh\\s+pr\\s+review\\b", "gh\\s+pr\\s+close\\b[^\\n]*--comment"]
scope: "tool"
---

Anything you post on GitHub appears under the user's name: thread replies, PR or issue comments, reviews, close comments, and resolving review threads.

- **Bot threads** (`greptile-apps`, `linear-code`, other `[bot]` authors): reply and resolve them only when a skill the user invoked tells you to.
- **Threads from a person** (e.g. a teammate's review): never reply, comment, or resolve on your own, even after you've fixed what they asked. Instead:
  1. make the code changes;
  2. show the user a draft reply for each thread in chat;
  3. ask whether to post them and whether to resolve the threads (`ask`);
  4. post only what the user approves, word for word.
- **PR comments**, including a `--comment` when closing a PR: ask first, unless the user dictated the text.

Check who wrote a thread's first comment (`author.login`) before every reply. When in doubt, don't post.