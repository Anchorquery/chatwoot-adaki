module Enterprise::AutoAssignment::AssignmentService
  private

  # Adaki coverage: filter out agents currently on absence unless they
  # have no coverage_user set (in which case absence resolver returns themselves).
  def filter_agents_by_team(agents, conversation)
    agents = super
    return agents if agents.nil?

    filter_agents_by_absences(agents)
  end

  def filter_agents_by_absences(agents)
    return agents if agents.respond_to?(:empty?) && agents.empty?

    agent_user_ids = if agents.respond_to?(:pluck)
                       agents.pluck(:user_id)
                     else
                       agents.map { |a| a.respond_to?(:user_id) ? a.user_id : a.id }
                     end
    return agents if agent_user_ids.empty?

    absent_user_ids = Adaki::Absence
                      .where(user_id: agent_user_ids)
                      .where(status: %w[scheduled active])
                      .active_at(Time.current)
                      .distinct
                      .pluck(:user_id)
    return agents if absent_user_ids.empty?

    if agents.respond_to?(:where)
      agents.where.not(user_id: absent_user_ids)
    else
      agents.reject { |a| absent_user_ids.include?(a.respond_to?(:user_id) ? a.user_id : a.id) }
    end
  end
end
