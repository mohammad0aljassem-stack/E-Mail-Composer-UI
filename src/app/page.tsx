import Link from "next/link";

export default function HomePage() {
  return (
    <main className="home">
      <h1>Email Composer UI</h1>
      <p>
        Phase 1: the canonical e-mail composer. Tiptap/ProseMirror JSON is the
        only editable source of truth; HTML and plain text are derived outputs.
      </p>
      <p>
        <Link href="/composer-lab">Open the composer laboratory</Link>
      </p>
    </main>
  );
}
