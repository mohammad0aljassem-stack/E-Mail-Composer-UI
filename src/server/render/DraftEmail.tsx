/**
 * React Email template for a canonical draft document.
 *
 * Every allowed node maps onto a React element; user content only ever
 * appears as React children (escaped by React) or as a link href that has
 * already passed the central URL policy. There is no
 * dangerouslySetInnerHTML anywhere in this tree.
 *
 * Direction handling: the outer document stays LTR (German business e-mail
 * default) while every paragraph and list item carries dir="auto" so Arabic
 * and mixed content stays readable.
 */

import {
  Body,
  Container,
  Head,
  Html,
  Link,
  Text,
} from "@react-email/components";
import type { CSSProperties, ReactNode } from "react";
import type {
  BlockNode,
  DraftDocument,
  InlineNode,
  ListItemNode,
} from "@/lib/composer/canonical";

const bodyStyle: CSSProperties = {
  backgroundColor: "#ffffff",
  color: "#1f2937",
  fontFamily: "-apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
  fontSize: "16px",
  lineHeight: "1.5",
  margin: 0,
};

const containerStyle: CSSProperties = {
  margin: "0 auto",
  maxWidth: "600px",
  padding: "16px",
};

const paragraphStyle: CSSProperties = {
  margin: "0 0 16px 0",
};

const tightParagraphStyle: CSSProperties = {
  margin: 0,
};

const listStyle: CSSProperties = {
  margin: "0 0 16px 0",
  paddingLeft: "24px",
};

const listItemStyle: CSSProperties = {
  margin: "0 0 4px 0",
};

const blockquoteStyle: CSSProperties = {
  borderLeft: "3px solid #d1d5db",
  color: "#4b5563",
  margin: "0 0 16px 0",
  paddingLeft: "12px",
};

const linkStyle: CSSProperties = {
  color: "#1d4ed8",
  textDecoration: "underline",
};

function renderInlineNode(node: InlineNode, key: number): ReactNode {
  if (node.type === "hardBreak") {
    return <br key={key} />;
  }
  let element: ReactNode = node.text;
  for (const mark of node.marks ?? []) {
    if (mark.type === "italic") {
      element = <em>{element}</em>;
    } else if (mark.type === "bold") {
      element = <strong>{element}</strong>;
    } else {
      element = (
        <Link href={mark.attrs.href} style={linkStyle}>
          {element}
        </Link>
      );
    }
  }
  return <span key={key}>{element}</span>;
}

function renderInline(nodes: InlineNode[] | undefined): ReactNode {
  if (!nodes || nodes.length === 0) {
    // A visible empty line for empty paragraphs.
    return " ";
  }
  return nodes.map((node, index) => renderInlineNode(node, index));
}

function renderListItem(item: ListItemNode, key: number): ReactNode {
  return (
    <li key={key} dir="auto" style={listItemStyle}>
      {item.content.map((child, index) =>
        renderBlock(child, index, { tight: true }),
      )}
    </li>
  );
}

function renderBlock(
  block: BlockNode,
  key: number,
  options: { tight?: boolean } = {},
): ReactNode {
  switch (block.type) {
    case "paragraph":
      return (
        <Text
          key={key}
          dir="auto"
          style={options.tight ? tightParagraphStyle : paragraphStyle}
        >
          {renderInline(block.content)}
        </Text>
      );
    case "bulletList":
      return (
        <ul key={key} style={listStyle}>
          {block.content.map((item, index) => renderListItem(item, index))}
        </ul>
      );
    case "orderedList":
      return (
        <ol key={key} start={block.attrs?.start ?? 1} style={listStyle}>
          {block.content.map((item, index) => renderListItem(item, index))}
        </ol>
      );
    case "blockquote":
      return (
        <blockquote key={key} style={blockquoteStyle}>
          {block.content.map((child, index) => renderBlock(child, index))}
        </blockquote>
      );
  }
}

export function DraftEmail({ document }: { document: DraftDocument }) {
  return (
    <Html lang="de" dir="ltr">
      <Head>
        <meta charSet="utf-8" />
      </Head>
      <Body style={bodyStyle}>
        <Container style={containerStyle}>
          {document.content.map((block, index) => renderBlock(block, index))}
        </Container>
      </Body>
    </Html>
  );
}
