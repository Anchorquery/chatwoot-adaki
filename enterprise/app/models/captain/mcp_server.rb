# frozen_string_literal: true

require 'digest'

# == Schema Information
#
# Table name: captain_mcp_servers
#
#  id                     :bigint           not null, primary key
#  command                :text
#  command_args           :jsonb            not null
#  description            :text
#  enabled                :boolean          default(TRUE), not null
#  endpoint_url           :text
#  last_discovered_at     :datetime
#  last_error             :text
#  metadata               :jsonb            not null
#  name                   :string           not null
#  slug                   :string           not null
#  timeout_seconds        :integer          default(20), not null
#  tools_cache            :jsonb            not null
#  transport_type         :string           default("streamable_http"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  platform_credential_id :bigint
#
class Captain::McpServer < ApplicationRecord
  class DiscoveryError < StandardError; end

  self.table_name = 'captain_mcp_servers'

  belongs_to :account
  belongs_to :platform_credential, optional: true

  enum :transport_type, {
    streamable_http: 'streamable_http',
    stdio: 'stdio'
  }, default: :streamable_http, validate: true

  before_validation :generate_slug

  validates :name, :slug, :transport_type, :timeout_seconds, presence: true
  validates :slug, uniqueness: { scope: :account_id }
  validates :timeout_seconds, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 60 }
  validates :endpoint_url, presence: true, if: :streamable_http?
  validates :command, presence: true, if: :stdio?
  validates :endpoint_url, length: { maximum: 2048 }, allow_blank: true
  validates :command, length: { maximum: 512 }, allow_blank: true
  include Concerns::SafeEndpointValidatable
  validate :credential_belongs_to_account

  scope :enabled, -> { where(enabled: true) }

  def tool_id_for(tool_name)
    base_slug = "#{slug}_#{tool_name.to_s.parameterize(separator: '_')}"
    prefixed = "mcp_#{base_slug}"
    return prefixed if prefixed.length <= 64

    digest = Digest::SHA1.hexdigest(tool_name.to_s)[0, 6]
    available_length = [64 - "mcp_".length - slug.length - digest.length - 2, 0].max
    truncated_tool = tool_name.to_s.parameterize(separator: '_')[0, available_length].to_s.sub(/_+\z/, '')
    "mcp_#{slug}_#{truncated_tool}_#{digest}"
  end

  def available_tool_metadata
    normalized_tools_cache.filter_map do |tool|
      tool_name = tool['name'] || tool[:name]
      next if tool_name.blank?

      {
        id: tool_id_for(tool_name),
        title: tool['title'] || tool[:title] || tool_name.to_s.humanize,
        description: tool['description'] || tool[:description] || '',
        icon: 'plug',
        mcp: true,
        server_id: id,
        server_name: name,
        server_slug: slug,
        tool_name: tool_name,
        input_schema: tool['inputSchema'] || tool[:inputSchema] || {}
      }
    end
  end

  def tool_instances(assistant)
    available_tool_metadata.filter_map do |tool_metadata|
      Captain::Tools::RegistryService.build_mcp_tool(assistant: assistant, server: self, tool_metadata: tool_metadata)
    end
  end

  def discover_tools!
    discovery = Platform::Mcp::DiscoveryService.new(server: self)
    tools = discovery.call

    update!(
      tools_cache: tools,
      last_discovered_at: Time.current,
      last_error: nil
    )

    self
  rescue StandardError => e
    update_columns(last_error: e.message, updated_at: Time.current)
    raise DiscoveryError, e.message
  end

  def normalized_tools_cache
    Array(tools_cache).map { |tool| tool.with_indifferent_access }
  end

  private

  def generate_slug
    return if slug.present?
    return if name.blank?

    candidate = name.parameterize(separator: '_')
    self.slug = candidate
  end

  def credential_belongs_to_account
    return if platform_credential_id.blank?
    return if platform_credential.blank?
    return if platform_credential.account_id.nil?
    return if platform_credential.account_id == account_id

    errors.add(:platform_credential_id, 'must belong to the same account or be global')
  end
end
