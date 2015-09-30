class Draft < ActiveRecord::Base
  belongs_to :user
  serialize :draft, JSON
  before_create :default_values
  after_create :set_native_id

  DRAFT_FORMS = [ # array of hashes provide flexibility to add additional fiels
    { form_partial_name: 'data_identification' },
    { form_partial_name: 'descriptive_keywords' },
    { form_partial_name: 'metadata_information' },
    { form_partial_name: 'temporal_extent' },
    { form_partial_name: 'spatial_extent' },
    { form_partial_name: 'acquisition_information' },
    { form_partial_name: 'distribution_information' }
  ]

  def self.get_next_form(cur_form_name)
    DRAFT_FORMS.each_with_index do |f, i|
      if f[:form_partial_name] == cur_form_name
        next_index = i + 1
        next_index = 0 if next_index == DRAFT_FORMS.size
        return DRAFT_FORMS[next_index][:form_partial_name]
      end
    end
    nil
  end

  def display_entry_title
    entry_title || '<Untitled Collection Record>'
  end

  def display_entry_id
    entry_id || '<Blank Entry Id>'
  end

  def update_draft(params)
    if params
      # pull out searchable fields if provided
      if params['entry_id']
        self.entry_title = params['entry_title'].empty? ? nil : params['entry_title']
        self.entry_id = params['entry_id'].empty? ? nil : params['entry_id']
      end

      # The provider_id isn't actually part of the metadata. You can think of that as the owner of the metadata. It's meta-metadata.
      # self.provider_id = ?

      # Convert {'0' => {'id' => 123'}} to [{'id' => '123'}]
      params = convert_to_arrays(params.clone)
      # Convert parameter keys to CamelCase for UMM
      json_params = params.to_hash.to_camel_keys
      # Merge new params into draft
      new_draft = draft.merge(json_params)
      # Remove empty params from draft
      new_draft = compact_blank(new_draft.clone)

      if new_draft
        self.draft = new_draft
        save
      end
    end
    # This keeps an empty form from sending the user back to draft_path when clicking on Save & Next
    true
  end

  def self.create_from_collection(collection, user, native_id)
    draft = Draft.find_or_create_by(native_id: native_id)
    draft.user = user
    draft.draft = collection
    draft.entry_id = collection['EntryId'].empty? ? nil : collection['EntryId']
    draft.entry_title = collection['EntryTitle'].empty? ? nil : collection['EntryTitle']
    draft.native_id = native_id
    draft.save
    draft
  end

  private

  INTEGER_KEYS = %w(
    number_of_sensors
    duration_value
    period_cycle_duration_value
    precision_of_seconds
  )
  NUMBER_KEYS = %w(
    size
    fees
    longitude
    latitude
    minimum_value
    maximum_value
    west_bounding_coordinate
    north_bounding_coordinate
    east_bounding_coordinate
    south_bounding_coordinate
    denominator_of_flattening_ratio
    semi_major_axis
    latitude_resolution
    longitude_resolution
    swath_width
    inclination_angle
    number_of_orbits
    start_circular_latitude
    distribution_size
  )
  BOOLEAN_KEYS = %w(
    ends_at_present_flag
  )

  def convert_to_arrays(object)
    case object
    when Hash
      # if the first key is an integer, change hash to array
      keys = object.keys
      if keys.first =~ /\d+/
        object = object.map { |_key, value| value }
        object.each do |value|
          convert_to_arrays(value)
        end
      else
        object.each do |key, value|
          if INTEGER_KEYS.include?(key)
            object[key] = value.to_i unless value.empty?
          elsif NUMBER_KEYS.include?(key)
            object[key] = convert_to_number(value)
          elsif BOOLEAN_KEYS.include?(key)
            object[key] = value == 'true' ? true : false unless value.empty?
          elsif key == 'resolutions'
            object[key] = value.map { |_key, resolution| convert_to_number(resolution) }
          elsif key == 'science_keywords'
            object[key] = convert_science_keywords(value)
          elsif key == 'access_constraints'
            # 'Value' shows up multiple times in the UMM. We just need to convert AccessConstraints/Value to a number
            value['value'] = convert_to_number(value['value']) if value['value']
            object[key] = value
          else
            if key == 'orbit_parameters'
              # There are two fields named 'Period' but only one of them is a number.
              # Convert the correct 'Period' to a number
              period = value['period']
              value['period'] = convert_to_number(period)
              object[key] = value
            end
            object[key] = convert_to_arrays(value)
          end
        end
      end
    # if value is array, loop through each hash
    when Array
      object.each do |obj|
        convert_to_arrays(obj)
      end
    end
    object
  end

  def convert_to_number(string)
    if string.is_a? Array
      string.map { |s| s.gsub(/[^\-0-9.]/, '').to_f unless s.empty? }
    else
      string.gsub(/[^\-0-9.]/, '').to_f unless string.empty?
    end
  end

  def compact_blank(node)
    return node.map { |n| compact_blank(n) }.compact.presence if node.is_a?(Array)
    return node if node == false
    return node.presence unless node.is_a?(Hash)
    result = {}
    node.each do |k, v|
      result[k] = compact_blank(v)
    end
    result = result.compact
    result.compact.presence
  end

  def convert_science_keywords(science_keywords)
    values = []
    if science_keywords.length > 0
      science_keywords.each do |keyword|
        value = {}
        keywords = keyword.split(' > ')
        value['Category'] = keywords[0] if keywords[0]
        value['Topic'] = keywords[1] if keywords[1]
        value['Term'] = keywords[2] if keywords[2]
        value['VariableLevel1'] = keywords[3] if keywords[3]
        value['VariableLevel2'] = keywords[4] if keywords[4]
        value['VariableLevel3'] = keywords[5] if keywords[5]
        value['DetailedVariable'] = keywords[6] if keywords[6]
        values << value
      end
    end
    values
  end

  def default_values
    self.draft ||= {}
  end

  def set_native_id
    self.native_id ||= "mmt_collection_#{id}"
    save
  end
end