class Plan < ActiveRecord::Base
  belongs_to :currency
  belongs_to :user
  # Lead organisation currently just plain text field
  # belongs_to :organisation
  has_many :template_instances, :dependent => :destroy
  has_many :template_instance_rights, :through => :template_instances
  has_many :templates, :through => :template_instances
  has_many :phase_edition_instances, :through => :template_instances
  has_many :answers, :through => :phase_edition_instances
  has_many :current_phase_edition_instances, :source => :phase_edition_instances, :through => :template_instances, :conditions =>  "template_instances.current_edition_id = phase_edition_instances.edition_id"
  has_many :current_answers, :source => :answers, :through => :current_phase_edition_instances 
  has_many :questions, :through => :answers

  belongs_to :repository
  has_many :repository_action_queues, :dependent => :destroy
  belongs_to :source_plan, :class_name => 'Plan', :foreign_key => 'duplicated_from_plan_id'
  has_many :duplicate_plans, :class_name => 'Plan', :foreign_key => 'duplicated_from_plan_id'

  attr_accessible :project, :currency_id, :budget, :start_date, :end_date, :lead_org, :other_orgs, :template_ids
  attr_accessible :repository_id
  accepts_nested_attributes_for :template_instances, :update_only => true, :allow_destroy => false

  validates_presence_of :project
  validates_presence_of :template_instances, :message => I18n.t('dmp.require_template')
  validate :validate_project_dates 
  attr_accessor :template_ids
  before_validation :update_template_instances
  after_initialize :load_template_instances
  
  
  def self.for_user(user)
    # Check all template instances for access rights for provided user
    user ||= User.new
    includes(:template_instance_rights)
      .where("plans.user_id = ? OR (? LIKE email_mask AND role_flags > 0)", user.id, user.email)
  end

  def question_counts
    self.answers.count(group: 'phase_edition_instances.id', conditions: 'answers.hidden = 0 AND answers.not_used = 0')
  end

  def answered_counts
    self.answers.count(group: 'phase_edition_instances.id', conditions: 'answers.answered <> 0 AND answers.hidden = 0 AND answers.not_used = 0')
  end
  
  def report_questions
    col = []
    self.current_phase_edition_instances.each do |pei|
      col += pei.report_questions
    end
    col
  end

  def child_questions(q_id)
    self.questions
      .where(parent_id: q_id)
      .order('answers.position')
      .all
  end

  def child_answered(q_id)
    !self.questions
      .where(parent_id: q_id, 'answers.answered' => true)
      .all
      .empty?
  end
  
  def include_question(q_id)
    result = false
    q = self.questions.where("questions.id" => q_id).first
    if q.nil?
      result = true
    else
      if q.dependency_question_id
        a = self.answers.where("answers.question_id = ? OR answers.dcc_question_id = ?", q_id, q_id).first
        if q.dependency_value.split('|').include? a.try(:answer)
          result = true
        end
      else
        result = true
      end
    end
    result
  end

  def user_list
    refs = {}
    rights = {}
    self.template_instance_rights.each do |tir|
      rights.merge!(tir.display_email_mask => [TemplateInstance::ROLES[tir.role_flags.to_i]]) do |key, oldval, newval| 
        combo = oldval || []
        combo |= newval
      end
      refs.merge!(tir.display_email_mask => {id: tir.id, rights: rights[tir.display_email_mask]})
    end
    refs
  end

  def common_rights
    ti_list = self.template_instances.collect(&:id)
    TemplateInstanceRight
      .select("email_mask, role_flags")
      .where(:template_instance_id => ti_list)
      .group("email_mask, role_flags")
      .having("count(*) = ?", ti_list.count)
  end
  
  def simple_rights?
    ti_list = self.template_instances.collect(&:id)
    tirs = TemplateInstanceRight
      .select("email_mask, role_flags")
      .where(:template_instance_id => ti_list)
      .group("email_mask, role_flags")
      .having("count(*) != ?", ti_list.count)
      .collect(&:email_mask)
    
    return tirs.size == 0
  end

  def external_writable
    !self.template_instance_rights.where(:role_flags => TemplateInstance::ROLES.index('write')).blank?
  end
  
  def current_repository_actions
    RepositoryActionQueue
      .where(plan_id: self.id, repository_id: self.repository_id)
  end
  

  
  protected
  
  # before_validation callback to handle adding template_instances
  def update_template_instances
    if !self.template_ids.nil? && self.template_ids.is_a?(Array)
      self.template_instances.each do |t|
        # We're not allowing deletion since this could lead to user losing data, 
        # and destroy should only happen after validation, not here
        #t.destroy unless template_ids.include?(t.template_id.to_s)
        self.template_ids.delete(t.template_id.to_s)
      end
      self.template_ids.each do |t|
        self.template_instances.build(:template_id => t) unless t.blank?
      end
      self.template_ids = self.template_instances.collect {|t| t.template_id}
    end
  end

  def load_template_instances
    if self.template_ids.nil?
      self.template_ids = self.template_instances.collect {|t| t.template_id} || []
    end
  end
  
  def validate_project_dates
    if !self.start_date.nil? && self.start_date < '1900-01-01'.to_date
      errors.add(:start_date, I18n.t('dmp.date_not_current'))
      self.start_date = nil
    end
    if !self.end_date.nil? && (self.start_date.nil? || self.end_date < self.start_date)
      errors.add(:end_date, I18n.t('dmp.end_before_start'))
      self.end_date = nil
    end
  end
end
