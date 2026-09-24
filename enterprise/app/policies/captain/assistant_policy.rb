class Captain::AssistantPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def stats?
    true
  end

  def tools?
    captain_manager?
  end

  def create?
    captain_manager?
  end

  def update?
    captain_manager?
  end

  def destroy?
    captain_manager?
  end

  def sync?
    captain_manager?
  end

  def playground?
    true
  end

  def generate_config?
    captain_manager?
  end

  private

  def captain_manager?
    administrator_or_custom_role_permission?('captain_manage')
  end
end
