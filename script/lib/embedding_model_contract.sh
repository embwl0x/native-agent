#!/usr/bin/env bash
# Build/fetch/release resource contract. Runtime loading and user installations
# remain owned by CoreMLEmbeddingProvider.
nativeagent_require_embedding_model() {
  local source="$1" links
  [[ -r "$source/embedding.json" && -d "$source/embedding.mlpackage" && -s "$source/vocab.txt" ]] || {
    echo "[embedding] incomplete model at $source: require embedding.json, embedding.mlpackage and vocab.txt" >&2
    return 1
  }
  jq -e '.model == "embedding.mlpackage" and .vocab == "vocab.txt"
    and .model_id == "bge-large-en-v1.5" and .dimensions == 1024' "$source/embedding.json" >/dev/null || {
    echo "[embedding] invalid manifest at $source/embedding.json" >&2
    return 1
  }
  links="$(find "$source/embedding.mlpackage" -type l -print -quit)" || return 1
  [[ -z "$links" && ! -L "$source/embedding.mlpackage" && ! -L "$source/embedding.json" && ! -L "$source/vocab.txt" ]] || {
    echo "[embedding] packaged model must contain regular local resources: $source" >&2
    return 1
  }
}
