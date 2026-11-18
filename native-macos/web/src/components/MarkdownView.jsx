import React, { useState } from 'react';
import { Check, Copy } from 'lucide-react';
import { copyText } from '../bridge.js';

function CodeBlock({ lang, code }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = async () => {
    if (await copyText(code)) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    }
  };
  return (
    <div className="md-code-wrap">
      <div className="md-code-head">
        <span>{lang || 'code'}</span>
        <button type="button" className="md-copy-btn" onClick={handleCopy}>
          {copied ? <><Check size={12} /> 已复制</> : <><Copy size={12} /> 复制</>}
        </button>
      </div>
      <pre className="codex-codeblock"><code>{code}</code></pre>
    </div>
  );
}

function renderInline(text, keyPrefix = 'in') {
  if (!text) return null;
  const tokens = text.split(/(`[^`\n]+`|\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*|~~[^~]+~~|\*[^*\n]+\*)/g);
  return tokens.map((seg, i) => {
    const k = `${keyPrefix}-${i}`;
    if (!seg) return null;
    if (seg.startsWith('`') && seg.endsWith('`') && seg.length >= 2) {
      return <code key={k} className="codex-inline-code">{seg.slice(1, -1)}</code>;
    }
    if (seg.startsWith('**') && seg.endsWith('**') && seg.length >= 4) {
      return <strong key={k}>{seg.slice(2, -2)}</strong>;
    }
    if (seg.startsWith('~~') && seg.endsWith('~~') && seg.length >= 4) {
      return <del key={k}>{seg.slice(2, -2)}</del>;
    }
    if (seg.startsWith('*') && seg.endsWith('*') && seg.length >= 2) {
      return <em key={k}>{seg.slice(1, -1)}</em>;
    }
    const linkMatch = seg.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (linkMatch) {
      const [, label, href] = linkMatch;
      return (
        <span
          key={k}
          className="md-link"
          title={href}
          onClick={() => copyText(href)}
        >
          {label}
        </span>
      );
    }
    return seg;
  });
}

function renderTextBlocks(chunk, baseKey) {
  const lines = chunk.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    if (!trimmed) {
      i++;
      continue;
    }

    // Horizontal rule
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      out.push(<hr key={`${baseKey}-hr-${i}`} className="md-hr" />);
      i++;
      continue;
    }

    // Heading
    const headingMatch = trimmed.match(/^(#{1,4})\s+(.*)$/);
    if (headingMatch) {
      const level = headingMatch[1].length;
      const Tag = `h${level}`;
      out.push(<Tag key={`${baseKey}-h-${i}`} className={`md-h${level}`}>{renderInline(headingMatch[2], `${baseKey}-hi-${i}`)}</Tag>);
      i++;
      continue;
    }

    // Table (header | row, separator |---|---)
    if (trimmed.includes('|') && i + 1 < lines.length && /^\s*\|?(\s*:?-{2,}:?\s*\|)+\s*:?-{2,}:?\s*\|?\s*$/.test(lines[i + 1])) {
      const parseRow = r => r.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim());
      const headers = parseRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trim().includes('|')) {
        rows.push(parseRow(lines[i]));
        i++;
      }
      out.push(
        <div key={`${baseKey}-tbl-${i}`} className="md-table-wrap">
          <table className="md-table">
            <thead>
              <tr>{headers.map((h, hi) => <th key={hi}>{renderInline(h, `${baseKey}-th-${i}-${hi}`)}</th>)}</tr>
            </thead>
            <tbody>
              {rows.map((r, ri) => (
                <tr key={ri}>
                  {headers.map((_, ci) => <td key={ci}>{renderInline(r[ci] || '', `${baseKey}-td-${i}-${ri}-${ci}`)}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
      continue;
    }

    // Blockquote
    if (trimmed.startsWith('>')) {
      const quoteLines = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        quoteLines.push(lines[i].trim().replace(/^>\s?/, ''));
        i++;
      }
      out.push(
        <blockquote key={`${baseKey}-bq-${i}`} className="md-quote">
          {renderInline(quoteLines.join('\n'), `${baseKey}-bqi-${i}`)}
        </blockquote>
      );
      continue;
    }

    // Unordered list
    if (/^\s*[-*+]\s+/.test(line)) {
      const items = [];
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*[-*+]\s+/, ''));
        i++;
      }
      out.push(
        <ul key={`${baseKey}-ul-${i}`} className="md-list">
          {items.map((item, idx) => <li key={idx}>{renderInline(item, `${baseKey}-uli-${i}-${idx}`)}</li>)}
        </ul>
      );
      continue;
    }

    // Ordered list
    if (/^\s*\d+\.\s+/.test(line)) {
      const items = [];
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*\d+\.\s+/, ''));
        i++;
      }
      out.push(
        <ol key={`${baseKey}-ol-${i}`} className="md-list">
          {items.map((item, idx) => <li key={idx}>{renderInline(item, `${baseKey}-oli-${i}-${idx}`)}</li>)}
        </ol>
      );
      continue;
    }

    // Paragraph (collect contiguous normal lines)
    const paraLines = [];
    while (
      i < lines.length &&
      lines[i].trim() !== '' &&
      !/^(#{1,4})\s+/.test(lines[i].trim()) &&
      !/^\s*[-*+]\s+/.test(lines[i]) &&
      !/^\s*\d+\.\s+/.test(lines[i]) &&
      !lines[i].trim().startsWith('>') &&
      !/^(-{3,}|\*{3,}|_{3,})$/.test(lines[i].trim())
    ) {
      paraLines.push(lines[i]);
      i++;
    }
    out.push(
      <p key={`${baseKey}-p-${i}`} className="md-p">
        {renderInline(paraLines.join('\n'), `${baseKey}-pi-${i}`)}
      </p>
    );
  }
  return out;
}

export default function MarkdownView({ text }) {
  if (!text) return null;
  const parts = text.split(/(```[\s\S]*?```)/g);
  return (
    <div className="codex-answer">
      {parts.map((part, idx) => {
        if (part.startsWith('```') && part.endsWith('```')) {
          const match = part.match(/^```([^\n]*)\n([\s\S]*)```$/);
          const lang = match ? match[1].trim() : '';
          const code = match ? match[2].replace(/\n$/, '') : part.slice(3, -3);
          return <CodeBlock key={idx} lang={lang} code={code} />;
        }
        return <React.Fragment key={idx}>{renderTextBlocks(part, `b${idx}`)}</React.Fragment>;
      })}
    </div>
  );
}
