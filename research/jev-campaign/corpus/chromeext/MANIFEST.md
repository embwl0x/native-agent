# MANIFEST — chromeext corpus

All pages fetched 2026-09-17 via HTTPS GET (Python urllib, desktop UA), article body extracted to markdown-ish text. SHA-256 is of the saved raw file including its two-line URL/fetch-date header.

| raw file | source ids | URL | fetch route | SHA-256 | notes |
|---|---|---|---|---|---|
| `raw/best-practices-policy.md` | — | https://developer.chrome.com/docs/webstore/best-practices | direct HTTPS GET | `84450784fe9a56088f018ef9b8f0e1f3e4bfb2880160e608bb3482c91f103032` | Fetched for context; no excerpt drawn. |
| `raw/blocking-web-requests.md` | 7fbc0fa1 | https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-requests | direct HTTPS GET | `da5c916292e41a9141df135c48fed980aa82fcc3540a52e12cbd6716c452a022` | Reached after the `blocking-web-request` (singular) slug returned 404; correct slug is plural. |
| `raw/blog-improved-dnr.md` | 05158f86, 2741637b | https://developer.chrome.com/blog/improvements-to-content-filtering-in-manifest-v3 | direct HTTPS GET | `5114e72ac091b48e11afa8fe182d59a1244378be405c5a6fd6857c08dedcb6b2` |  |
| `raw/blog-resuming-mv3.md` | f67dbbf9 | https://developer.chrome.com/blog/resuming-the-transition-to-mv3 | direct HTTPS GET | `307334ddde1b4fbd662cd0081ed09db267ae42a5632594cd2ea865d3a447709b` |  |
| `raw/chromium-blog-mv2-phaseout.md` | e8621005 | https://blog.chromium.org/2024/05/manifest-v2-phase-out-begins.html | direct HTTPS GET | `10bd36e88e1a8fbfdf5c6113e4620df8188d7a9850fdc7e178a64bc5a8c4a33b` |  |
| `raw/content-filtering.md` | — | https://developer.chrome.com/docs/extensions/develop/concepts/content-filtering | direct HTTPS GET | `a5e64759c448f81aa1071078db139878041119c74feac5efa25e3d21baaf083f` | Fetched for context (300,000 shared static pool / 330,000 figure); no excerpt drawn. |
| `raw/dnr-api.md` | a65606cd, 7c82d4f5 | https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest | direct HTTPS GET | `8865b932d7f82ad637fdfa108cce2616f1d37e52673707e55cac509b365a2de1` |  |
| `raw/enterprise-policy-mv2.md` | — | https://chromeenterprise.google/policies/atomic-groups/?policy=ExtensionManifestV2Availability | direct HTTPS GET | `d30dc262ca82ceee942d0527483138608193a20e2ddee1c91a2cf1ad671d765d` | UNAVAILABLE: page is a client-rendered SPA; zero text recovered without JS. ExtensionManifestV2Availability semantics sourced from the MV2 support timeline and the Chromium blog instead. |
| `raw/improve-security.md` | 30473f4d | https://developer.chrome.com/docs/extensions/develop/migrate/improve-security | direct HTTPS GET | `4ef7dcee8dfeb72a0169c75ebabbd47d7906e8e10eb245069d515ddb9b64e5db` |  |
| `raw/mv2-deprecation-timeline.md` | 79250f1d, 095a5599 | https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline | direct HTTPS GET | `59cb0a053315e948d23b3fb0579b2af73a723936ad7d45de443a1331fc1f9cf9` |  |
| `raw/policy-code-readability.md` | — | https://developer.chrome.com/docs/webstore/program-policies/code-readability | direct HTTPS GET | `991cf50a9a2e068d45cac643949e02a8c46d4998f5f0baac67324a8663580935` | PARTIAL: near-empty body after extraction. |
| `raw/policy-mv3-requirements.md` | a9519154 | https://developer.chrome.com/docs/webstore/program-policies/mv3-requirements | direct HTTPS GET | `17897a9782342968b4aa74b492d72f64a5e08fc8e744be7688e1f47a97be023f` |  |
| `raw/policy-permissions.md` | — | https://developer.chrome.com/docs/webstore/program-policies/permissions | direct HTTPS GET | `6a8b2b9ce38528ab61d0870e176707d778141ad1a05365d61fbf8609956e5320` | Fetched for context; no excerpt drawn. |
| `raw/program-policies.md` | — | https://developer.chrome.com/docs/webstore/program-policies | direct HTTPS GET | `d7a3148f00b8913536bba9cc14c23480cc997588cdff8b1e0611748f842e0c21` | PARTIAL: policy body is behind client-side accordions; only section headings recovered. Substantive policy text taken from the per-policy subpages instead. |
| `raw/remote-hosted-code.md` | — | https://developer.chrome.com/docs/extensions/develop/migrate/remote-hosted-code | direct HTTPS GET | `d17e3e885ecfdafdf354c0c588529aff64220a8f9825d83d2639109c3948d880` | Fetched for context; no excerpt drawn. |
| `raw/review-process.md` | — | https://developer.chrome.com/docs/webstore/review-process | direct HTTPS GET | `7392267d2805e6b4e1108204761ab290cb7e26bd7c52caace0c0233cf13ce0bb` | PARTIAL: no 'expedited review' prose recovered from the rendered body; expedited-review facts sourced from the Chromium blog and DNR reference instead. |
| `raw/webrequest-api.md` | 688c66f7 | https://developer.chrome.com/docs/extensions/reference/api/webRequest | direct HTTPS GET | `9b843048ee5b235e64a327c98ecd79ee630859b809cc7bd63af2d6e7fe833f36` |  |
| `raw/what-is-mv3.md` | — | https://developer.chrome.com/docs/extensions/develop/migrate/what-is-mv3 | direct HTTPS GET | `b0dfe8f28fb9f10418f4b412455763c321190a5e0f7ab880aacd396b3fce0047` | Fetched for context; no excerpt drawn. |

## Pages attempted and not recovered

| URL | outcome |
|---|---|
| https://developer.chrome.com/docs/extensions/develop/migrate/blocking-web-request | 404 — wrong slug; superseded by `blocking-web-requests` |
| https://developer.chrome.com/blog/more-mv3-updates | 404 |
| https://blog.chromium.org/2023/11/resuming-manifest-v3-phase-out-in-2024.html | 404 |
| https://blog.chromium.org/2021/09/improving-extension-security-with-mv3.html | 404 |
| https://chromestatus.com/feature/5199847124992000 | 200 but client-rendered; no text recoverable without JS |
| https://chromeenterprise.google/policies/ | 200 but client-rendered; no text recoverable without JS |
| https://developer.chrome.com/docs/webstore/program-policies/single-page | 404 |

## Recovery notes

- WebFetch was attempted first but returns model-written summaries rather than page text, so it was not used as a source of excerpt text. All 12 verbatim excerpts were extracted from the raw files in `raw/` and machine-checked against them (whitespace- and list-bullet-normalized substring match).
- Excerpt text normalizes the extractor's stray whitespace around punctuation and drops list bullet glyphs; no words were added, removed, or reordered. Non-adjacent spans within one page are joined with ` [...] `.
- No source excerpt crosses a page boundary.
