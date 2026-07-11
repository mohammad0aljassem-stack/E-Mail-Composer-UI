import type { Metadata } from "next";
import { DraftEditorScreen } from "@/components/drafts/DraftEditorScreen";
import "../../../drafts.css";

export const metadata: Metadata = {
  title: "Draft editor",
};

export default async function DraftEditorPage({
  params,
}: {
  params: Promise<{ workspaceId: string; draftId: string }>;
}) {
  const { workspaceId, draftId } = await params;
  return <DraftEditorScreen workspaceId={workspaceId} draftId={draftId} />;
}
