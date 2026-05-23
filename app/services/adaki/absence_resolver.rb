class Adaki::AbsenceResolver
  def initialize(user)
    @user = user
  end

  # Returns coverage user when @user is currently absent, else returns @user.
  def effective_assignee
    absence = current_absence
    return @user if absence.blank?
    return @user if absence.coverage_user_id.blank?

    absence.coverage_user
  end

  def absent?
    current_absence.present?
  end

  def current_absence
    @current_absence ||= Adaki::Absence
                         .for_user(@user)
                         .where(status: %w[scheduled active])
                         .active_at(Time.current)
                         .order(start_at: :asc)
                         .first
  end
end
