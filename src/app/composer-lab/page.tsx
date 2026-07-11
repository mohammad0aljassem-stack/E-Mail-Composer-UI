import type { Metadata } from "next";
import { ComposerLab } from "@/components/composer/ComposerLab";

export const metadata: Metadata = {
  title: "Composer laboratory",
};

export default function ComposerLabPage() {
  return <ComposerLab />;
}
