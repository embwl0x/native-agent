# Corpus Manifest — Kubernetes (deprecation, PSP→PSA, feature gates)

Fetch date: **2026-09-17**. All raw files under `raw/`.

Fetch routes:
- **WebFetch** — `https://kubernetes.io/docs/reference/using-api/deprecation-policy/` was fetched with the WebFetch tool to confirm the rendered rule text.
- **curl + HTML→text** — all `kubernetes.io` pages were additionally retrieved with `curl -sSL` and reduced to plain text with a local tag stripper (`<main>` extraction, script/style/nav/footer removal, table cells joined with ` | `). This route is byte-exact for the prose and is what every excerpt is quoted from.
- **curl (raw markdown)** — archived (pre-removal) docs were taken from the `kubernetes/website` `release-1.24` branch as raw Markdown, because the versioned docs hosts (`v1-24.docs.kubernetes.io`, `v1-25.docs.kubernetes.io`) fail TLS hostname verification (see "Partial recovery" below).

| Raw file | Source URL | Route | SHA-256 | Record ids derived |
|---|---|---|---|---|
| `raw/deprecation-policy.md` | https://kubernetes.io/docs/reference/using-api/deprecation-policy/ | WebFetch + curl/HTML→text | `b82ae2af405bf083a2e0a1458963471b60635c5343e4bd87e543ccac50c7027b` | `42415d70`, `623f9176` |
| `raw/deprecation-guide.md` | https://kubernetes.io/docs/reference/using-api/deprecation-guide/ | curl/HTML→text | `90b5129fa2192d263cbd6c6346c38deae9cd241af2ad9defac83f487ea562f84` | *(none — context only)* |
| `raw/pod-security-admission.md` | https://kubernetes.io/docs/concepts/security/pod-security-admission/ | curl/HTML→text | `ddd8e3ae743f6d89e0e7aed47ca9b649647a7c06a75f3731b0739f9ec7fa67df` | `99443563`, `59a92ca1` |
| `raw/pod-security-standards.md` | https://kubernetes.io/docs/concepts/security/pod-security-standards/ | curl/HTML→text | `c148f01e3237f95839b7b1a5a5d1914824c4bf397248dd2838f6131731d1efe9` | `9a850f58`, `534f6251`, `d8c4412b` |
| `raw/migrate-from-psp.md` | https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/ | curl/HTML→text | `f7126d956ce805513acb66f13e74f955e3fa064c24d265e7aa84157087c8a021` | `dc691178` |
| `raw/enforce-standards-namespace-labels.md` | https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/ | curl/HTML→text | `464ea88cdaca6c96d223e02045c0353d2a0d3b6e5d6e994414bcded38cbcc24a` | `506354c6` |
| `raw/feature-gates.md` | https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/ | curl/HTML→text | `111b4f8677353ae07c2d6aa843e59921c7a443c8ffe31fe2b855adef97d7f5ea` | *(none — context only)* |
| `raw/blog-psp-deprecation-2021.md` | https://kubernetes.io/blog/2021/04/06/podsecuritypolicy-deprecation-past-present-and-future/ | curl/HTML→text | `a6e936643f736ead7a0e4c915d5038a3a2c1fe292a3ea8c27c6edf9a392862ff` | *(none — context only)* |
| `raw/blog-psp-removal-1-25.md` | https://kubernetes.io/blog/2022/08/04/upcoming-changes-in-kubernetes-1-25/ | curl/HTML→text | `cedd7c7332ceffc0bd5d04e9912c1209e8efae914cbf4e66016da19e15b4e552` | *(none — context only)* |
| `raw/blog-psa-stable-1-25.md` | https://kubernetes.io/blog/2022/08/25/pod-security-admission-stable/ | curl/HTML→text | `c343e46746d0c3e596b91fca775efa15a57f47fa452a8fc8061d9dfdbba131b3` | `1400190c`, `f5bfd0f3` |
| `raw/v1-24-pod-security-policy.md` | https://raw.githubusercontent.com/kubernetes/website/release-1.24/content/en/docs/concepts/security/pod-security-policy.md | curl (raw markdown, fallback) | `145676188210f3c5cd07179d8c6da79b7cc0368e12bdda2073106c05b86c3ce7` | `d689b13a` |
| `raw/v1-24-pod-security-standards.md` | https://raw.githubusercontent.com/kubernetes/website/release-1.24/content/en/docs/concepts/security/pod-security-standards.md | curl (raw markdown, fallback) | `6375571a322d3b719e4fd9a2550652598febb4f7a3c8f1dd7a33c128b9cf7777` | *(none — corroboration only, see note)* |
| `raw/v1-24-psa-docs.md` | https://raw.githubusercontent.com/kubernetes/website/release-1.24/content/en/docs/concepts/security/pod-security-admission.md | curl (raw markdown, fallback) | `37404e71c38fb9335734506ae82077dbaa762299dd9a2250e2696c8c7cd5b631` | *(none — context only)* |

## Partial recovery / unavailable pages

- **`https://v1-24.docs.kubernetes.io/...` and `https://v1-25.docs.kubernetes.io/...` were UNAVAILABLE.** Both returned `curl (60) SSL: no alternative certificate subject name matches target host name`. No excerpt in this corpus comes from those hosts. The archived-version requirement for category (d) was satisfied instead by the `release-1.24` branch of the `kubernetes/website` repository, which is the upstream source of those same rendered pages.
- **`raw/v1-24-pod-security-standards.md` is partial for quoting purposes.** It is raw Hugo/HTML-in-Markdown (`<td>`, `<code>`, shortcodes), so the pre-v1.25 Seccomp wording in it ("Seccomp profile must be explicitly set to one of the allowed values. Both the `Unconfined` profile and the *absence* of a profile are prohibited." — with no Linux-only carve-out) could not be quoted cleanly without stripping markup. It is retained as corroboration that the carve-out is genuinely new in v1.25; the quoted (a)/(d) contrast is carried by `blog-psa-stable-1-25.md` and the current standards page instead.
- **`raw/deprecation-guide.md`, `raw/feature-gates.md`, `raw/blog-psp-deprecation-2021.md`, `raw/blog-psp-removal-1-25.md`** were fetched in full and verified, but no excerpt was drawn from them; they are kept as provenance for the surrounding claims in `labels/gold.md`.
- The HTML→text conversion collapses tables into ` | `-separated cells. Two excerpts (`9a850f58`, `d8c4412b`) begin with residual table-cell separators from the Pod Security Standards tables. This is the raw file's content verbatim; no words were altered.
