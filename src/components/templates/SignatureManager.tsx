"use client";

import { useState } from "react";
import type { DraftDocument } from "@/lib/composer/canonical";
import type { SignatureRecord } from "@/lib/phase2/contracts";
import {
  signatureDocumentFromText,
  signatureTextFromDocument,
} from "@/lib/signatures/text-to-doc";

export interface SignatureSaveInput {
  /** Present when editing an existing signature; absent when creating. */
  id?: string;
  name: string;
  body_json: DraftDocument;
}

export interface SignatureManagerProps {
  signatures: SignatureRecord[];
  onSave: (input: SignatureSaveInput) => void;
  onSetDefault: (id: string) => void;
  onDelete: (id: string) => void;
  onApply: (signature: SignatureRecord) => void;
}

/**
 * Presentational signature manager: lists signatures (with a default badge),
 * offers set-default / delete / apply actions, and a create/edit form whose
 * body is plain text — each line becomes one canonical paragraph. No HTML
 * is ever built from the text.
 */
export function SignatureManager({
  signatures,
  onSave,
  onSetDefault,
  onDelete,
  onApply,
}: SignatureManagerProps) {
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [bodyText, setBodyText] = useState("");

  const resetForm = (): void => {
    setEditingId(null);
    setName("");
    setBodyText("");
  };

  return (
    <section aria-label="Signatures" className="composer-panel">
      <h2>Signatures</h2>
      {signatures.length === 0 ? (
        <p>No signatures yet.</p>
      ) : (
        <ul>
          {signatures.map((signature) => (
            <li key={signature.id}>
              <span>{signature.name}</span>{" "}
              {signature.is_default ? <strong>Default</strong> : null}{" "}
              <span className="composer-lab-actions">
                <button
                  type="button"
                  aria-label={`Apply signature ${signature.name}`}
                  onClick={() => onApply(signature)}
                >
                  Apply
                </button>
                <button
                  type="button"
                  aria-label={`Edit signature ${signature.name}`}
                  onClick={() => {
                    setEditingId(signature.id);
                    setName(signature.name);
                    setBodyText(signatureTextFromDocument(signature.body_json));
                  }}
                >
                  Edit
                </button>
                <button
                  type="button"
                  aria-label={`Set signature ${signature.name} as default`}
                  disabled={signature.is_default}
                  onClick={() => onSetDefault(signature.id)}
                >
                  Set default
                </button>
                <button
                  type="button"
                  aria-label={`Delete signature ${signature.name}`}
                  onClick={() => {
                    if (editingId === signature.id) {
                      resetForm();
                    }
                    onDelete(signature.id);
                  }}
                >
                  Delete
                </button>
              </span>
            </li>
          ))}
        </ul>
      )}
      <form
        className="composer-link-form"
        aria-label={editingId ? "Edit signature" : "Create signature"}
        onSubmit={(event) => {
          event.preventDefault();
          if (name.trim().length === 0) {
            return;
          }
          onSave({
            ...(editingId === null ? {} : { id: editingId }),
            name,
            body_json: signatureDocumentFromText(bodyText),
          });
          resetForm();
        }}
      >
        <h3>{editingId ? "Edit signature" : "New signature"}</h3>
        <p>
          <label htmlFor="signature-name">Name</label>{" "}
          <input
            id="signature-name"
            type="text"
            dir="auto"
            aria-label="Signature name"
            value={name}
            onChange={(event) => setName(event.target.value)}
          />
        </p>
        <p>
          <label htmlFor="signature-body">Body (one paragraph per line)</label>{" "}
          <textarea
            id="signature-body"
            dir="auto"
            aria-label="Signature body"
            rows={4}
            value={bodyText}
            onChange={(event) => setBodyText(event.target.value)}
          />
        </p>
        <span className="composer-lab-actions">
          <button type="submit" disabled={name.trim().length === 0}>
            {editingId ? "Save changes" : "Create signature"}
          </button>
          {editingId ? (
            <button type="button" onClick={resetForm}>
              Cancel edit
            </button>
          ) : null}
        </span>
      </form>
    </section>
  );
}
