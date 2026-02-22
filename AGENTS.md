# S2T Project Rules

## Skill Binding
- For corrected transcript ingestion, use `$speech-dataset-pairing` workflow and keep project-specific submission through `s2t-controller submit-correction`.

## Corrected Text Dataset Rule
- Training pairs must always use the human-corrected transcript, not raw ASR output.
- When a corrected phrase is provided, submit it with `s2t-controller submit-correction` and keep the text exactly as provided (only controller-side whitespace normalization is allowed).
- Never create dataset `.txt` entries from `last_transcript.txt` automatically.

## Pairing Rule
- `submit-correction` must pair the corrected text with the latest pending audio cluster captured by `s2t-controller` (consecutive pending samples within `S2T_DATASET_MULTI_SEGMENT_GAP_SEC`).
- For global skill fallback matching, use strict 30-second window and require exactly one candidate audio; otherwise mark unmatched.
- Do not bypass the queue; ETL must be triggered via queue files consumed by `s2t-dataset-etl.service`.
- If the user sends corrected text in chat and there is pending audio, submit it via `s2t-controller submit-correction` from this session (unless the user explicitly says not to store it).

## Sudo Prompt Policy
- Never ask for sudo password repeatedly.
- Before any privileged command, run `~/.codex/bin/sudo-gate.sh` first.
- If the last prompt attempt was less than 300 seconds ago, do not prompt again.
- Interactive sudo prompt is allowed at most once per 5 minutes.
