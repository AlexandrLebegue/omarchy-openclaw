// Minimal, safe Markdown rendering for the OpenClaw transcript.
//
// Everything is HTML-escaped first, then a small set of inline constructs is
// turned into Qt rich-text tags. Links and images are deliberately reduced to
// their label: model output must not be able to trigger a network request from
// a bar panel.

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function format(value) {
  var text = escapeHtml(value)

  text = text.replace(/```([\s\S]*?)```/g, function(_, code) {
    return "<br><span style=\"font-family:monospace;\">" +
      String(code).replace(/\n/g, "<br>") + "</span><br>"
  })

  text = text.replace(/`([^`\n]+)`/g, "<span style=\"font-family:monospace;\">$1</span>")
  text = text.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
  text = text.replace(/__([^_\n]+)__/g, "<b>$1</b>")
  text = text.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>")
  text = text.replace(/^\s*#{1,6}\s+(.+)$/gm, "<b>$1</b>")
  text = text.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
  text = text.replace(/^\s*[-*]\s+/gm, "• ")
  text = text.replace(/\n/g, "<br>")

  return text
}
