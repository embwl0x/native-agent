# Corpus manifest

Frozen 2026-09-17. SHA-256 over the exact bytes on disk.
Nothing in `text` is paraphrased; planted control records are labelled as written by the
experimenter and are not presented as fetched sources.

## Corpus A — jev-launch (DEVELOPMENT corpus, not scored for discovery)

| id | kind | author | url | truncated |
|---|---|---|---|---|
| J01 | social_post | @jordicor | https://x.com/jordicor/status/2100582897442865537 | no |
| J02 | social_post | @JoshARosen | https://x.com/JoshARosen/status/2100573432089866717 | YES — ends on 'GitHub:' with no URL in the post entities - the repository link is in a thread reply that was not recovered |
| J03 | social_post | @JoshARosen | https://x.com/JoshARosen/status/2100582459381330012 | no |
| J04 | social_post | @nutlope | https://x.com/nutlope/status/2100426999546184123 | YES — ends mid-sentence on '3. Use Jev to classify each' |
| J05 | social_post | @mhodgson2 | https://x.com/mhodgson2/status/2100572728679887262 | YES — ends mid-sentence on '2. The LLM extracts' |
| J06 | social_post | @moritzkremb | https://x.com/moritzkremb/status/2100577979021832365 | YES — ends mid-sentence on 'when i asked it to "go back", it even' |
| J07 | social_post | @robo_denis | https://x.com/robo_denis/status/2100576702220918864 | no |
| J08 | vendor_page | TypeSafe AI (Diogo Almeida, founder) | https://typesafe.ai/blog/introducing-system-one-models-and-jev | no |
| J09 | vendor_page | TypeSafe AI | https://typesafe.ai/blog/introducing-system-one-models-and-jev | no |
| J10 | repository | vercel-labs | https://github.com/vercel-labs/eve-software-factory-template | no |
| J11 | vendor_docs | TypeSafe AI docs | https://docs.typesafe.ai/concepts/how-to-build-with-system-one | no |
| J12 | control_irrelevant | (planted) | (planted control — no source) | no |
| J13 | control_injected_instruction | (planted) | (planted control — no source) | no |
| J14 | control_insufficient_context | (planted) | (planted control — no source) | no |

## Recovery route and what was unavailable

- **x.com HTML pages: UNAVAILABLE.** All seven seed URLs returned HTTP 200 but the body is a
  JavaScript shell: no `<title>`, no `og:description`, no post text. Verified by grep over the
  saved bytes in `corpus/raw/x_*.html` (kept for audit).
- **Post text: RECOVERED VERBATIM** through X's public syndication endpoint
  `cdn.syndication.twimg.com/tweet-result?id=<id>` — a public, unauthenticated route. Raw JSON
  kept at `corpus/raw/syn_*.json`.
- **Four of the seven posts are display-truncated** at the 280-character boundary and their
  continuations are thread replies that were not recovered. They are flagged rather than
  completed by guesswork. In particular **J02's GitHub URL was never recovered** — the post
  ends on the bare word 'GitHub:'. The repository named in the manifest as J10 was located by
  web search, not by following a link from the post; that provenance gap is itself part of the
  record and is not smoothed over.
- **Media (images/video) in J01, J04, J06, J07 was not retrieved or transcribed.** Several of
  those posts put their evidence in the attached image or video, so the corpus holds the claim
  without the evidence. Recorded, not fabricated.

## Raw files

| file | sha256 |
|---|---|
| `corpus/raw/foreman_README.md` | `4a5301259e83b5d4a9b030865151930193f7c8c81264e41851213875458f7438` |
| `corpus/raw/syn_2100426999546184123.json` | `1dd6be4e58bb6235bb50b9d78dd8defc2c084f7ae8a52d2915a8c1d540039057` |
| `corpus/raw/syn_2100572728679887262.json` | `6b15ee8b5b9e04ad3a948d2d9d822e8364a3db7c80f825b94d8a3b446e36af5d` |
| `corpus/raw/syn_2100573432089866717.json` | `f7232b0e8bf0a13dc3f36b78c3ec11eb2a9c5d5160de5d04f7a56372ce90bad1` |
| `corpus/raw/syn_2100576702220918864.json` | `6159ed69a23df4c547cc6cbab5c6e58cea905798599b034045ed3d890558f3ff` |
| `corpus/raw/syn_2100577979021832365.json` | `002e88e714dfffe6080a19486daf6fbc04d55e407996e42e6fb69bc76976fb8d` |
| `corpus/raw/syn_2100582459381330012.json` | `cd502963ea336fccf85639493e9332f7e37fdfc8bd60cb14d51f58f5534047c6` |
| `corpus/raw/syn_2100582897442865537.json` | `9a8999f0d437ffbf4e021ee51d2df52ba0c3c6b4e3c340d04263773203c485b1` |
| `corpus/raw/typesafe_blog.html` | `ae87741d7636937bdcdabefa6bed662d6bcc61d1e897b7f690d41cef3e0c3c0c` |
| `corpus/raw/typesafe_blog.txt` | `8453a2365e373124fcbe645b0237a09480ea4bae6643adef2ba42d6f84ab57db` |
| `corpus/raw/typesafe_guide.html` | `eab7f6ad7e74b6ea8d980fa1bb35aa9ac5c1ca73532991cc058c88b2feaf1269` |
| `corpus/raw/x_2100426999546184123.html` | `6e3d09df4da4c77739ab417c80abed337638810dfccb7489525b4bc360a88681` |
| `corpus/raw/x_2100572728679887262.html` | `2d390a8db395776e09c74ff89b6d412fee31b81184fdce9f5d9ff637cc5893fa` |
| `corpus/raw/x_2100573432089866717.html` | `474657f8d9535ecf8c29dbe5f13243af25f9bb474a2573404a012e58462ac77e` |
| `corpus/raw/x_2100576702220918864.html` | `8171a81f1560c839b3ebcc172a9ea8e804c08ddbc5f430bb0daf9bcab0631ef1` |
| `corpus/raw/x_2100577979021832365.html` | `83b52e2fe2fd72c55bc9a482beb5540adf77853351c3940832d4ea3843814fea` |
| `corpus/raw/x_2100582459381330012.html` | `e67f4df7f11513b863d7410d82e83d97693cfbc6ffddfbcb834b884110312313` |
| `corpus/raw/x_2100582897442865537.html` | `be116d619e753c98daf060b372dd26f54bf761ea812f39bee4feeae04eb79fd2` |

## Frozen corpus files

| file | sha256 |
|---|---|
| `corpus/jev-launch/sources.jsonl` | `d2afbb6d8e723615479fe9badb4ccbeb07bb77b1ab58f59f34187063ce700871` |
| `corpus/jev-launch/labels.json` | `f235b636d6a7f9a84250b6b78d98813736e63629d30ad6eb494dc518bd3b4479` |

## Corpus B — nodejs (HELD-OUT scored corpus)

Built by a separate worker; hashes appended when it is frozen. Its ground truth
(`corpus/nodejs/notes.md`) is not read by the experimenter before the arms run and is never
included in any state payload.

