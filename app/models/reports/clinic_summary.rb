class Reports::ClinicSummary
  attr_accessor :day, :span
  attr_reader   :patients, :procedures, :procedure_count, :procedure_value, 
                :prescriptions, :prescription_count, :prescription_value, 
                :grand_total, :next_chart_number, :xrays, :checkouts
  
  def initialize(day=Date.today, span="All")
    reload(day,span)
  end
  
  def reload(day, span)
    @day, @span = day, span
    @procedures, @prescriptions = [], []
    
    if day == "All"
      @patients = Patient.all
    else
      @day = Date.parse(day) if day.kind_of? String
      
      @patients = Patient.all(:conditions => [patients_conditions, @day])
    end
    
    unless span == "All"
      span_time = Time.parse(span)
      
      @patients.reject! do |p|
        p.created_at.to_time.hour > span_time.hour
      end
    end
    
    collect_procedures
    collect_prescriptions
    
    @xrays = @patients.reject {|p| p.flows.find(:first, :conditions => {:area_id => ClinicArea::XRAY}).nil? }.length
    @xrays ||= 0
    
    @checkouts = @patients.reject {|p| p.flows.find(:first, :conditions => {:area_id => ClinicArea::CHECKOUT}).nil? }.length
    @checkouts ||= 0
    
    @grand_total = @procedure_value + @prescription_value
    
    @next_chart_number = Patient.maximum(:id) || 0
    @next_chart_number += 1
  end
  
  def date_sql
    if ENV['RAILS_ENV']=='production'
      # Use MySQL Style Conditions
      "Date(CONVERT_TZ(created_at,'UTC','EST'))"
    else
      "date(created_at, '#{Time.zone.utc_offset} seconds')"
    end
  end
  
  private
  
  def collect_procedures    
    @patients.map {|p| @procedures += p.patient_procedures }
    
    @procedures = @procedures.group_by(&:procedure).map do |procedure, count|
      [procedure, count.length, procedure.cost * count.length]
    end
    
    @procedure_count = @procedures.sum {|p| p[1] }
    @procedure_count ||= 0
    
    @procedure_value = @procedures.sum {|p| p.last }
    @procedure_value ||= 0
  end
  
  def collect_prescriptions
    @patients.map {|p| @prescriptions += p.patient_prescriptions }
    
    @prescriptions = @prescriptions.group_by(&:prescription).map do |prescription, count|
      [prescription, count.length, prescription.cost * count.length]
    end
    
    @prescription_count = @prescriptions.sum {|p| p[1] }
    @prescription_count ||= 0
    
    @prescription_value = @prescriptions.sum {|p| p.last }
    @prescription_value ||= 0
  end
  
  def patients_conditions
    date_sql + " = ?"
  end
end