import React from 'react';

export default function DiffView({ diffText }) {
  if (!diffText || !diffText.trim()) {
    return <div className="diff-empty">工作区暂无未提交的代码变更。</div>;
  }
  const lines = diffText.split('\n');
  return (
    <div className="diff-view">
      {lines.map((line, i) => {
        let cls = 'diff-line';
        if (line.startsWith('diff --git') || line.startsWith('index ') || line.startsWith('--- ') || line.startsWith('+++ ')) {
          cls += ' diff-meta';
        } else if (line.startsWith('@@')) {
          cls += ' diff-hunk';
        } else if (line.startsWith('+')) {
          cls += ' diff-add';
        } else if (line.startsWith('-')) {
          cls += ' diff-del';
        }
        return (
          <div key={i} className={cls}>
            <span>{line || ' '}</span>
          </div>
        );
      })}
    </div>
  );
}
