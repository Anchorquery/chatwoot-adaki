class Api::V1::Accounts::Captain::McpServersController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::McpServer) }
  before_action :set_mcp_server, only: %i[show update destroy test discover]

  def index
    servers = mcp_servers.map { |server| serialize_server(server) }
    render json: {
      payload: servers,
      meta: {
        total_count: servers.length,
        page: params[:page].presence || 1
      }
    }
  end

  def show
    render json: serialize_server(@mcp_server, include_tools: true)
  end

  def create
    @mcp_server = mcp_servers.create!(mcp_server_params)
    render json: serialize_server(@mcp_server), status: :created
  end

  def update
    @mcp_server.update!(mcp_server_params)
    render json: serialize_server(@mcp_server)
  end

  def destroy
    @mcp_server.destroy!
    head :no_content
  end

  def test
    result = Platform::Mcp::HealthCheckService.new(server: @mcp_server).call
    render json: result
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def discover
    @mcp_server.discover_tools!
    render json: serialize_server(@mcp_server, include_tools: true)
  rescue Captain::McpServer::DiscoveryError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def set_mcp_server
    @mcp_server = mcp_servers.find(params[:id])
  end

  def mcp_servers
    @mcp_servers ||= Current.account.captain_mcp_servers.order(created_at: :desc)
  end

  def serialize_server(server, include_tools: false)
    payload = {
      id: server.id,
      name: server.name,
      slug: server.slug,
      description: server.description,
      transport_type: server.transport_type,
      endpoint_url: server.endpoint_url,
      command: server.command,
      command_args: server.command_args,
      enabled: server.enabled,
      timeout_seconds: server.timeout_seconds,
      platform_credential_id: server.platform_credential_id,
      credential_hint: server.platform_credential&.token_hint,
      tools_count: server.normalized_tools_cache.count,
      last_error: server.last_error,
      last_discovered_at: server.last_discovered_at,
      created_at: server.created_at,
      updated_at: server.updated_at
    }

    payload[:tools] = server.available_tool_metadata if include_tools
    payload
  end

  def mcp_server_params
    params.require(:mcp_server).permit(
      :name,
      :description,
      :transport_type,
      :endpoint_url,
      :command,
      :enabled,
      :timeout_seconds,
      :platform_credential_id,
      command_args: []
    )
  end
end
