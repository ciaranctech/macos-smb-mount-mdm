# Workflow Standards

This repository is maintained as a polished, customer-facing product.

## Content Rules

- Do **not** include references to AI tools, assistants, or internal automation platforms in:
  - script headers/comments
  - README or user documentation
  - release notes and commit descriptions intended for end users
- Keep all wording vendor-neutral and product-focused.
- Document only final behavior, supported options, and production outcomes.

## Pre-Release Checklist

Before publishing changes:

1. Search for restricted references:
   ```bash
   grep -RinE 'openclaw|claw workflow|\bAI\b' .
   ```
2. Confirm README reflects final product state only.
3. Confirm script headers and comments are customer-appropriate.

## Commit Hygiene

- Use clear, professional commit messages.
- Keep internal implementation process details out of user-facing docs.
