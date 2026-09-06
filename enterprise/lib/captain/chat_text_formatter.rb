# Rewrites a Captain reply so it reads well on messaging channels that render
# plain text instead of Markdown (WhatsApp through an Evolution bridge on a
# Channel::Api inbox, WhatsApp Cloud API, SMS).
#
# The LLM writes Chatwoot-flavoured Markdown, which the dashboard renders
# fine, but on the customer's phone a `### Heading` shows up as literal
# hashes and a `[text](url)` link as brackets and parentheses. Only the
# constructs those channels cannot show are flattened:
#
# - ATX headings become a bold line (`### Tarjetas` → `**Tarjetas**`).
# - Markdown links/images become the bare URL, or `text (url)` when the
#   link text is not the URL itself. Autolinks (`<https://…>`) lose the brackets.
# - Horizontal rules are dropped, 3+ blank lines collapse to one.
#
# Inline emphasis is left in Chatwoot Markdown on Channel::Api on purpose:
# Evolution's Chatwoot integration already rewrites `**bold**` → `*bold*`,
# `~~x~~` → `~x~` and `` `code` `` → ``` ```code``` ``` on its way to
# WhatsApp (receiveWebhook in its chatwoot.service.ts), and converting here
# too would make it turn our `*bold*` into `_italic_`. WhatsApp Cloud API
# has no such bridge, so it gets WhatsApp's own markers; SMS gets none.
class Captain::ChatTextFormatter
  # How each chat channel wants inline emphasis. Channels not listed here
  # (web widget, email, Telegram…) render Markdown/HTML themselves and are
  # left untouched.
  EMPHASIS_STYLE = {
    'Channel::Api' => :markdown,
    'Channel::Whatsapp' => :whatsapp,
    'Channel::Sms' => :plain,
    'Channel::TwilioSms' => :plain
  }.freeze

  HEADING = /\A\s{0,3}\#{1,6}\s+(?<title>.+?)\s*\#*\s*\z/
  HORIZONTAL_RULE = /\A\s{0,3}(?:[-*_]\s*){3,}\z/
  # `[text](url)` and `![alt](url)`, with an optional `"title"` after the URL.
  MARKDOWN_LINK = /(?<image>!)?\[(?<text>[^\]]*)\]\((?<url>[^)\s]+)(?:\s+"[^"]*")?\)/
  AUTOLINK = %r{<(?<url>https?://[^>\s]+)>}
  BOLD = /\*\*(?<text>[^*\n]+?)\*\*/
  STRIKETHROUGH = /~~(?<text>[^~\n]+?)~~/

  def self.chat_channel?(channel_type)
    EMPHASIS_STYLE.key?(channel_type.to_s)
  end

  # Returns +text+ unchanged for channels that render Markdown themselves.
  def self.format(text, channel_type:)
    return text unless chat_channel?(channel_type)

    new(text, emphasis: EMPHASIS_STYLE.fetch(channel_type.to_s)).call
  end

  def initialize(text, emphasis: :markdown)
    @text = text.to_s
    @emphasis = emphasis
  end

  def call
    return @text if @text.blank?

    lines = @text.split("\n", -1).map { |line| flatten_block(line) }
    text = flatten_links(lines.join("\n"))
    text = apply_emphasis(text)
    text.gsub(/\n{3,}/, "\n\n").strip
  end

  private

  def flatten_block(line)
    return '' if line.match?(HORIZONTAL_RULE)

    heading = line.match(HEADING)
    return line unless heading

    title = heading[:title].strip
    title = title.delete_prefix('**').delete_suffix('**') if title.start_with?('**') && title.end_with?('**')
    "**#{title}**"
  end

  def flatten_links(text)
    text = text.gsub(MARKDOWN_LINK) do
      match = Regexp.last_match
      link_text = match[:text].strip
      url = match[:url]
      # An image's alt text is a description, not a label worth showing.
      match[:image] || same_target?(link_text, url) ? url : "#{link_text} (#{url})"
    end
    text.gsub(AUTOLINK) { Regexp.last_match[:url] }
  end

  # `[https://x.com/](https://x.com/)`, `[x.com](https://x.com)` and an empty
  # label all mean "just show the URL".
  def same_target?(link_text, url)
    return true if link_text.blank?

    normalize(link_text) == normalize(url)
  end

  def normalize(value)
    value.strip.sub(%r{\Ahttps?://}i, '').sub(/\Awww\./i, '').chomp('/').downcase
  end

  def apply_emphasis(text)
    case @emphasis
    when :whatsapp
      text.gsub(BOLD) { "*#{Regexp.last_match[:text]}*" }
          .gsub(STRIKETHROUGH) { "~#{Regexp.last_match[:text]}~" }
    when :plain
      text.gsub(BOLD) { Regexp.last_match[:text] }
          .gsub(STRIKETHROUGH) { Regexp.last_match[:text] }
    else
      text
    end
  end
end
