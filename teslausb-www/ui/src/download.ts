export function downloadText(filename: string, text: string): void {
  const el = document.createElement('a');
  el.href = 'data:text/plain;charset=utf-8,' + encodeURIComponent(text);
  el.download = filename;
  el.style.display = 'none';
  document.body.appendChild(el);
  el.click();
  document.body.removeChild(el);
}
