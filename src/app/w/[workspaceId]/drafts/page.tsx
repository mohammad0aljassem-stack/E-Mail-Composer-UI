import type { Metadata } from "next";
import { DraftList } from "@/components/drafts/DraftList";
import "../../drafts.css";

export const metadata: Metadata = {
  title: "Drafts",
};

export default async function DraftsPage({
  params,
}: {
  params: Promise<{ workspaceId: string }>;
}) {
  const { workspaceId } = await params;
  return <DraftList workspaceId={workspaceId} />;
}
