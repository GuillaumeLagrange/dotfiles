// Rebuilds the GitHub review sandbox (GuillaumeLagrange/diffy-tests): one PR per concern.
// Run from the omp eval kernel (Bun): `const s = await import('<abs path>/build.js'); await s.buildAll()`.
// Needs `gh` authenticated with repo scope. Force-pushes every sandbox branch.

const OWNER = 'GuillaumeLagrange';
const REPO = 'diffy-tests';
const DIR = '/tmp/diffy-sandbox';
const F = '```';

let clock = Date.parse('2026-01-01T00:00:00Z');
const bash = Bun.which('bash');

export async function sh(cmd, cwd = DIR) {
  clock += 60_000;
  const date = new Date(clock).toISOString();
  const proc = Bun.spawn([bash, '-c', cmd], {
    cwd,
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'diffy', GIT_AUTHOR_EMAIL: 'guillaume.lagrange@gmail.com',
      GIT_COMMITTER_NAME: 'diffy', GIT_COMMITTER_EMAIL: 'guillaume.lagrange@gmail.com',
      GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date,
    },
    stdout: 'pipe', stderr: 'pipe',
  });
  const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(`${cmd}\n${out}${err}`);
  return out;
}

export async function gql(query, variables = {}) {
  const proc = Bun.spawn(['gh', 'api', 'graphql', '--input', '-'], { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' });
  proc.stdin.write(JSON.stringify({ query, variables }));
  proc.stdin.end();
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  const res = JSON.parse(out || '{}');
  if (res.errors) throw new Error(`${query.slice(0, 80)}…\n${JSON.stringify(res.errors)}`);
  return res.data;
}

const lines = (n, f = (i) => `line ${i}`) => Array.from({ length: n }, (_, i) => f(i + 1));
const write = (path, ls) => Bun.write(`${DIR}/${path}`, ls.join('\n') + '\n');
const read = async (path) => (await Bun.file(`${DIR}/${path}`).text()).replace(/\n$/, '').split('\n');
async function edit(path, fn) { const ls = await read(path); fn(ls); await write(path, ls); }
async function commit(msg) { await sh(`git add -A && git commit -qm ${JSON.stringify(msg)}`); return (await sh('git rev-parse HEAD')).trim(); }
const push = (...refs) => sh(`git push -qf origin ${refs.join(' ')}`);

async function prInfo(number) {
  const d = await gql(`query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ pullRequest(number:$n){ id headRefOid } } }`, { o: OWNER, r: REPO, n: number });
  return d.repository.pullRequest;
}

async function waitHead(number, sha) {
  for (let i = 0; i < 30; i++) {
    if ((await prInfo(number)).headRefOid === sha) return;
    await Bun.sleep(2000);
  }
  throw new Error(`PR #${number} head never reached ${sha}`);
}

async function openPr(base, head, title, body) {
  const url = (await sh(`gh pr create --repo ${OWNER}/${REPO} --base ${base} --head ${head} --title ${JSON.stringify(title)} --body-file -  <<'EOF'\n${body}\nEOF`)).trim();
  return Number(url.split('/').pop());
}

async function editPrBody(number, body) {
  await sh(`gh pr edit ${number} --repo ${OWNER}/${REPO} --body-file - <<'EOF'\n${body}\nEOF`);
}

// Submitted review on `commit` with `threads`; returns thread ids by the body's first word.
async function review(prId, commit, body, threads, event = 'COMMENT') {
  const d = await gql(`mutation($pr:ID!,$c:GitObjectID!,$b:String!,$t:[DraftPullRequestReviewThread],$e:PullRequestReviewEvent){
    addPullRequestReview(input:{pullRequestId:$pr, commitOID:$c, body:$b, threads:$t, event:$e}){ pullRequestReview{ id } } }`,
    { pr: prId, c: commit, b: body, t: threads, e: event });
  return d.addPullRequestReview.pullRequestReview.id;
}

async function threadIds(number) {
  const d = await gql(`query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ pullRequest(number:$n){ reviewThreads(first:100){ nodes{ id comments(first:1){ nodes{ body commit{oid} } } } } } } }`, { o: OWNER, r: REPO, n: number });
  return Object.fromEntries(d.repository.pullRequest.reviewThreads.nodes.map((t) => [t.comments.nodes[0].body.split(/\s/)[0], { id: t.id, commit: t.comments.nodes[0].commit?.oid }]));
}

async function reply(prId, threadId, body, submit = true) {
  const d = await gql(`mutation($pr:ID!){ addPullRequestReview(input:{pullRequestId:$pr}){ pullRequestReview{ id } } }`, { pr: prId });
  const rid = d.addPullRequestReview.pullRequestReview.id;
  await gql(`mutation($r:ID!,$t:ID!,$b:String!){ addPullRequestReviewThreadReply(input:{pullRequestReviewId:$r, pullRequestReviewThreadId:$t, body:$b}){ comment{ id } } }`, { r: rid, t: threadId, b: body });
  if (submit) await gql(`mutation($r:ID!){ submitPullRequestReview(input:{pullRequestReviewId:$r, event:COMMENT}){ pullRequestReview{ id } } }`, { r: rid });
  return rid;
}

const resolve = (threadId) => gql(`mutation($t:ID!){ resolveReviewThread(input:{threadId:$t}){ thread{ isResolved } } }`, { t: threadId });

// GitHub "position": 1-based index of the diff line below the file's first @@ header.
async function position(base, commit, path, newLine) {
  const diff = (await sh(`git diff -U3 ${base} ${commit} -- ${path}`)).split('\n');
  let pos = -1, nl = 0;
  for (const l of diff) {
    const h = l.match(/^@@ -\d+(?:,\d+)? \+(\d+)/);
    if (h) { if (pos >= 0) pos++; else pos = 0; nl = Number(h[1]) - 1; continue; }
    if (pos < 0) continue;
    pos++;
    if (!l.startsWith('-')) nl++;
    if (!l.startsWith('-') && nl === newLine) return pos;
  }
  throw new Error(`line ${newLine} not in diff ${base}..${commit} ${path}`);
}

async function init() {
  await sh(`rm -rf ${DIR} && mkdir -p ${DIR}`, '/tmp');
  await sh(`git init -q -b main && git remote add origin git@github.com:${OWNER}/${REPO}.git`);
  await Bun.write(`${DIR}/README.md`, [
    '# diffy-tests', '',
    'Review sandbox for diffy.nvim. Rebuilt by `nvim/diffy/sandbox/build.js` in the dotfiles repo.', '',
    'Each open PR tests one concern; its description lists every comment and where it must show.', '',
  ].join('\n'));
  return commit('readme');
}

// ── PR: placement ────────────────────────────────────────────────────────────────────────────
async function placement() {
  await sh('git checkout -q main && git checkout -qb base/placement');
  await write('f.txt', lines(100));
  await write('h.txt', lines(40, (i) => `rename me ${i}`));
  await write('del.txt', lines(20, (i) => `delete me ${i}`));
  const B0 = await commit('B0 fixture');
  await sh('git checkout -qb sandbox/placement');
  await edit('f.txt', (f) => { f[9] = 'line 10 P1'; f[10] = 'line 11 P1'; f[11] = 'line 12 P1'; });
  const P1 = await commit('P1 edit f 10-12');
  await edit('f.txt', (f) => { f[49] = 'line 50 P2'; f[10] = 'line 11 P2'; });
  const P2 = await commit('P2 edit f 50, re-edit f 11');
  await sh('git mv h.txt i.txt && git rm -q del.txt');
  await edit('i.txt', (f) => { f[4] = 'rename me 5 P3'; });
  await write('g.txt', lines(10, (i) => `new ${i}`));
  const P3 = await commit('P3 rename h→i + edit, delete del.txt, add g.txt');
  await sh('git checkout -q base/placement');
  await edit('f.txt', (f) => { f[89] = 'line 90 BASE'; });
  const M1 = await commit('M1 base moves: f 90');
  await sh('git checkout -q sandbox/placement && git merge -q --no-edit base/placement');
  const P4 = (await sh('git rev-parse HEAD')).trim();
  await edit('f.txt', (f) => { f[69] = 'line 70 P5'; });
  const P5 = await commit('P5 edit f 70');
  await push('main', 'base/placement', 'sandbox/placement');
  const n = await openPr('base/placement', 'sandbox/placement',
    'Placement: comments tracked across commits, force-push, merge, rename, delete, outdated (do not push)',
    '(filled after build)');
  const pr = await prInfo(n);
  await waitHead(n, P5);

  // Round A: written on P5, which is force-pushed away next.
  await review(pr.id, P5, 'round A (on P5, later force-pushed away)', [
    { path: 'f.txt', line: 70, side: 'RIGHT', body: 'A1 @P5 R70 — P5 is amended and L70 changes again → outdated; resolved' },
    { path: 'f.txt', line: 67, side: 'RIGHT', body: 'A2 @P5 R67 context — tracked by GitHub through the force-push and shift' },
  ]);
  let ids = await threadIds(n);
  await resolve(ids.A1.id);

  await edit('f.txt', (f) => { f[69] = 'line 70 P5 amended'; f.splice(60, 0, 'inserted 1', 'inserted 2'); });
  await sh('git commit -q --amend --no-edit -a');
  const P5b = (await sh('git rev-parse HEAD')).trim();
  await push('sandbox/placement');
  await waitHead(n, P5b);
  await edit('f.txt', (f) => { f.unshift('top 1', 'top 2', 'top 3'); });
  const P6 = await commit('P6 insert 3 lines at top of f (shifts everything)');
  await edit('g.txt', (f) => { f.push('new 11'); });
  const P7 = await commit('P7 unrelated: g.txt only');
  await push('sandbox/placement');
  await waitHead(n, P7);
  for (let i = 0; i < 20 && (await threadIds(n)).A2.commit !== P7; i++) await Bun.sleep(2000);

  // Round B: written after the last push, so the API has not remapped them (lazy until next push).
  await review(pr.id, P1, 'round B on P1', [
    { path: 'f.txt', line: 10, side: 'RIGHT', body: 'B1 @P1 R10 — unchanged later → head R13, visible in P1/P2 views' },
    { path: 'f.txt', line: 11, side: 'RIGHT', body: 'B2 @P1 R11 — P2 re-edits L11 → outdated; visible in P1 view only; resolved' },
    { path: 'f.txt', startLine: 10, line: 12, side: 'RIGHT', startSide: 'RIGHT', body: 'B3 @P1 R10-12 — L11 inside the range changes in P2, endpoints do not → head R13-15, P1 R10-12, P2 R10-12' },
    { path: 'f.txt', startLine: 12, line: 14, side: 'RIGHT', startSide: 'RIGHT', body: 'B4 @P1 R12-14 — range unchanged later → head R15-17; resolved' },
  ]);
  await review(pr.id, P2, 'round B on P2', [
    { path: 'f.txt', line: 50, side: 'RIGHT', body: 'B5 @P2 R50 — unchanged later → head R53; hidden in P1 view (L50 differs there)' },
  ]);
  await review(pr.id, P7, 'round B on head', [
    { path: 'f.txt', line: 13, side: 'RIGHT', body: 'B6 @head R13 — changed line (line 10 P1)' },
    { path: 'f.txt', line: 18, side: 'RIGHT', body: 'B7 @head R18 — context line (3 below the hunk), not a changed line' },
    { path: 'f.txt', line: 10, side: 'LEFT', body: 'B8 @head L10 — old side (merge-base content "line 10")' },
    { path: 'f.txt', startLine: 15, line: 53, side: 'RIGHT', startSide: 'RIGHT', body: 'B9 @head R15-53 — range spanning two hunks and unchanged lines between' },
    { path: 'i.txt', line: 5, side: 'RIGHT', body: 'B10 @head i.txt R5 — renamed file (h.txt → i.txt)' },
    { path: 'del.txt', line: 3, side: 'LEFT', body: 'B11 @head del.txt L3 — deleted file, old side' },
    { path: 'g.txt', body: 'B12 @head g.txt — file-level comment (no line)' },
  ]);
  ids = await threadIds(n);
  await resolve(ids.B2.id);
  await resolve(ids.B4.id);

  const s = (x) => x.slice(0, 7);
  await editPrBody(n, [
    'Tests where comments show in diffy vs github.com. **Do not push to this branch**: round B relies on no',
    'push having happened since it was written (the API has not remapped it yet; github.com remaps live).', '',
    `Commits: P1 \`${s(P1)}\` · P2 \`${s(P2)}\` · P3 \`${s(P3)}\` · merge \`${s(P4)}\` (base M1 \`${s(M1)}\`) · P5 amended \`${s(P5b)}\` (was \`${s(P5)}\`) · P6 \`${s(P6)}\` · P7 head \`${s(P7)}\``, '',
    '| id | written on | where it must show | state |',
    '|----|-----------|--------------------|-------|',
    '| A1 | P5 (gone) R70 | nowhere inline (outdated); comments panel only | resolved |',
    '| A2 | P5 (gone) R67 | head R72; P1 R67; P2 R67 | |',
    '| B1 | P1 R10 | head R13; P1 R10; P2 R10 | |',
    '| B2 | P1 R11 | P1 R11 only (outdated at head) | resolved |',
    '| B3 | P1 R10-12 | head R13-15; P1 R10-12; P2 R10-12 (only endpoints are tracked) | |',
    '| B4 | P1 R12-14 | head R15-17; P1 R12-14; P2 R12-14 | resolved |',
    '| B5 | P2 R50 | head R53; P2 R50; hidden in P1 | |',
    '| B6 | head R13 | head R13; P1 R10; P2 R10 (tracked backwards) | |',
    '| B7 | head R18 | head R18; P1 R15; P2 R15 (context line) | |',
    '| B8 | head L10 | head old side L10; P1 old side L10; hidden in P2 (its old side is P1) | |',
    '| B9 | head R15-53 | head R15-53; P2 R12-50; hidden in P1 (L50 differs) | |',
    '| B10 | head i.txt R5 | head i.txt R5 (rename) | |',
    '| B11 | head del.txt L3 | head del.txt old side L3 (behind "Load diff" on github.com) | |',
    '| B12 | head g.txt | head g.txt, file-level | |',
  ].join('\n'));
  return { number: n, shas: { B0, P1, P2, P3, M1, P4, P5, P5b, P6, P7 } };
}

// ── PR: content ──────────────────────────────────────────────────────────────────────────────
const LONG = ('This is one very long line that never wraps in the source markdown, so diffy has to decide how to wrap it in '
  + 'a float and how to truncate it in a virt_lines summary. ').repeat(3).trim();

async function content() {
  await sh('git checkout -q main && git checkout -qb base/content');
  await write('f.txt', lines(60));
  await commit('fixture');
  await sh('git checkout -qb sandbox/content');
  await edit('f.txt', (f) => { for (let i = 9; i <= 13; i++) f[i] = `line ${i + 1} K1`; });
  const K1 = await commit('K1 edit f 10-14');
  await edit('f.txt', (f) => { for (let i = 29; i <= 33; i++) f[i] = `line ${i + 1} K2`; });
  const K2 = await commit('K2 edit f 30-34');
  await push('base/content', 'sandbox/content');
  const body = [
    'Tests comment **content** rendering and round-trips. Every comment starts with its id.', '',
    'This description itself is multi-line markdown:', '',
    '- a list', '- with `inline code`', '', `${F}lua`, "print('code in the PR description')", F, '',
    '| id | where | content | state |', '|----|-------|---------|-------|',
    '| C1 | head R10-12 | multi-paragraph: list, nested list, quote, heading, table, long line, emoji | |',
    '| C2 | head R13 | code blocks: lua, diff, nested fences (~~~ around ```) | |',
    '| C3 | head R14 | single-line suggestion | resolved |',
    '| C4 | head R30-31 | multi-line suggestion, 2 lines → 3 | |',
    '| C5 | head R32-33 | deletion suggestion (empty block) | |',
    '| C6 | K1 R11-12 | suggestion with prose before and after, on an intermediate commit | |',
    '| C7 | head R34 | thread with 2 replies (multi-line bodies, one reply is a suggestion) | resolved |',
    '| C8 | head L30-32 | multi-line range on the old side, multi-line body | |',
    '| C9 | head R12 | body with bare line breaks, no blank lines | |', '',
    'Plus two conversation comments (not attached to code).',
  ].join('\n');
  const n = await openPr('base/content', 'sandbox/content',
    'Content: multi-line bodies, code blocks, suggestions, reply chains, resolved threads, conversation', body);
  const pr = await prInfo(n);
  await waitHead(n, K2);
  await review(pr.id, K2, 'Review body\nspanning several lines.\n\n- with a list', [
    { path: 'f.txt', startLine: 10, line: 12, side: 'RIGHT', startSide: 'RIGHT', body: [
      'C1 multi-paragraph body on a multi-line range', '',
      'First paragraph explains the problem.', 'It continues on a second source line of the same paragraph.', '',
      '- bullet one', '- bullet two', '  - nested bullet', '1. numbered', '2. list', '',
      '> quoted text', '> spanning two lines', '', '## A heading inside a comment', '',
      '| col a | col b |', '|-------|-------|', '| 1     | 2     |', '', LONG, '', 'Last line. 🎉'].join('\n') },
    { path: 'f.txt', line: 13, side: 'RIGHT', body: [
      'C2 code blocks', '', `${F}lua`, 'local function f(x)', '  return x + 1', 'end', F, '',
      `${F}diff`, '- old', '+ new', F, '', '~~~markdown', `${F}rust`, 'fn main() {}', F, '~~~'].join('\n') },
    { path: 'f.txt', line: 14, side: 'RIGHT', body: `C3 single-line suggestion\n\n${F}suggestion\nline 14 K1 (suggested)\n${F}` },
    { path: 'f.txt', startLine: 30, line: 31, side: 'RIGHT', startSide: 'RIGHT',
      body: `C4 multi-line suggestion, 2 lines → 3\n\n${F}suggestion\nline 30 suggested\nline 30.5 inserted\nline 31 suggested\n${F}` },
    { path: 'f.txt', startLine: 32, line: 33, side: 'RIGHT', startSide: 'RIGHT', body: `C5 deletion suggestion\n\n${F}suggestion\n${F}` },
    { path: 'f.txt', line: 34, side: 'RIGHT', body: 'C7 thread root\n\nShould this line exist at all?' },
    { path: 'f.txt', startLine: 30, line: 32, side: 'LEFT', startSide: 'LEFT', body: 'C8 old-side range\n\nThese three original lines\nwere fine as they were.' },
    { path: 'f.txt', line: 12, side: 'RIGHT', body: 'C9 bare line breaks\nsecond line\nthird line\nfourth line' },
  ]);
  await review(pr.id, K1, 'review on K1', [
    { path: 'f.txt', startLine: 11, line: 12, side: 'RIGHT', startSide: 'RIGHT', body: [
      'C6 suggestion on an intermediate commit', '', 'Prose before the suggestion.', '',
      `${F}suggestion`, 'line 11 K1 (suggested on K1)', 'line 12 K1 (suggested on K1)', F, '', 'Prose after the suggestion.'].join('\n') },
  ]);
  const ids = await threadIds(n);
  await reply(pr.id, ids.C7.id, `C7 reply 1\n\nI disagree, because:\n\n1. reason one\n2. reason two\n\n${F}diff\n- old\n+ new\n${F}`);
  await reply(pr.id, ids.C7.id, `C7 reply 2 — suggestion in a reply\n\n${F}suggestion\nline 34 K2 (suggested in reply)\n${F}`);
  await resolve(ids.C7.id);
  await resolve(ids.C3.id);
  await sh(`gh pr comment ${n} --repo ${OWNER}/${REPO} --body 'Conversation comment, single line.'`);
  await sh(`gh pr comment ${n} --repo ${OWNER}/${REPO} --body-file - <<'EOF'\nConversation comment, multi-line.\n\n- item\n\n${F}sh\necho hi\n${F}\nEOF`);
  return { number: n, shas: { K1, K2 } };
}

// ── PR: pending ──────────────────────────────────────────────────────────────────────────────
async function pending() {
  await sh('git checkout -q main && git checkout -qb base/pending');
  await write('f.txt', lines(40));
  const base = await commit('fixture');
  await sh('git checkout -qb sandbox/pending');
  await edit('f.txt', (f) => { for (let i = 4; i <= 6; i++) f[i] = `line ${i + 1} Q1`; });
  const Q1 = await commit('Q1 edit f 5-7');
  await edit('f.txt', (f) => { f[19] = 'line 20 Q2'; });
  const Q2 = await commit('Q2 edit f 20');
  await edit('f.txt', (f) => { f[29] = 'line 30 Q3'; });
  const Q3 = await commit('Q3 edit f 30');
  await push('base/pending', 'sandbox/pending');
  const s = (x) => x.slice(0, 7);
  const body = [
    'Tests `:Diffy review pull`. The viewer (repo owner) has an **unsubmitted pending review** here; only the',
    'owner sees it. Do not submit or delete it.', '',
    `Commits: Q1 \`${s(Q1)}\` · Q2 \`${s(Q2)}\` · Q3 head \`${s(Q3)}\``, '',
    '| id | where | kind | state |', '|----|-------|------|-------|',
    '| D1 | head R30 | published thread, gets a pending reply (E4) | |',
    '| D2 | head R20 | published thread | resolved |',
    '| E1 | Q1 R5-7 | pending thread on an intermediate commit (review commitOID = Q1), multi-line body | pending |',
    '| E2 | head R29 | pending thread added at head (addPullRequestReviewThread) | pending |',
    '| E3 | Q2 R20 | pending thread on another commit (legacy addPullRequestReviewComment + position) | pending |',
    '| E4 | reply to D1 | pending reply, multi-line body | pending |',
  ].join('\n');
  const n = await openPr('base/pending', 'sandbox/pending',
    'Pending review: unsubmitted threads on several commits and a pending reply (do not submit)', body);
  const pr = await prInfo(n);
  await waitHead(n, Q3);
  await review(pr.id, Q3, 'published review', [
    { path: 'f.txt', line: 30, side: 'RIGHT', body: 'D1 published thread (has a pending reply E4)' },
    { path: 'f.txt', line: 20, side: 'RIGHT', body: 'D2 published thread, resolved' },
  ]);
  const ids = await threadIds(n);
  await resolve(ids.D2.id);
  const d = await gql(`mutation($pr:ID!,$c:GitObjectID!,$t:[DraftPullRequestReviewThread]){ addPullRequestReview(input:{pullRequestId:$pr, commitOID:$c, threads:$t}){ pullRequestReview{ id } } }`,
    { pr: pr.id, c: Q1, t: [{ path: 'f.txt', startLine: 5, line: 7, side: 'RIGHT', startSide: 'RIGHT', body: 'E1 pending on Q1 R5-7\n\nmulti-line\nbody' }] });
  const rid = d.addPullRequestReview.pullRequestReview.id;
  await gql(`mutation($r:ID!){ addPullRequestReviewThread(input:{pullRequestReviewId:$r, path:"f.txt", line:29, side:RIGHT, body:"E2 pending at head R29"}){ thread{ id } } }`, { r: rid });
  const pos = await position(base, Q2, 'f.txt', 20);
  await gql(`mutation($r:ID!,$c:GitObjectID!,$p:Int!){ addPullRequestReviewComment(input:{pullRequestReviewId:$r, commitOID:$c, path:"f.txt", position:$p, body:"E3 pending on Q2 R20 (legacy position)"}){ comment{ id } } }`, { r: rid, c: Q2, p: pos });
  await gql(`mutation($r:ID!,$t:ID!){ addPullRequestReviewThreadReply(input:{pullRequestReviewId:$r, pullRequestReviewThreadId:$t, body:"E4 pending reply to D1\\n\\nsecond paragraph\\nwith a line break"}){ comment{ id } } }`, { r: rid, t: ids.D1.id });
  return { number: n, shas: { base, Q1, Q2, Q3 }, pendingReviewId: rid, e3Position: pos };
}

export async function buildAll() {
  await init();
  const out = { placement: await placement(), content: await content(), pending: await pending() };
  await sh(`git checkout -q main`);
  return out;
}
