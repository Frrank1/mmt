# Controller methods that allows developers to get this data without
# making an HTTP request (with the exception of the CMR call)
module ChooserEndpoints
  extend ActiveSupport::Concern

  def render_collections_for_chooser(collections)
    # The chooser expects an array of arrays, so that's what we'll give it
    render json: {
        'hits': collections.fetch('hits', 0),
        'items': collections.fetch('items', []).map do |collection|
          [
              collection.fetch('meta', {}).fetch('concept-id'),
              [
                  collection.fetch('umm', {}).fetch('entry-id'),
                  collection.fetch('umm', {}).fetch('entry-title')
              ].join(' | ')
          ]
        end
    }
  end

  # Retrieve collections from CMR
  def get_provider_collections(params = {})
    collection_params = {
      'provider' => current_user.provider_id,
      'page_size' => 25
    }.merge(params)

    if collection_params.key?('short_name')
      collection_params['short_name'].concat('*')

      # In order to search with the wildcard parameter we need to tell CMR to use it
      collection_params['options'] = {
        'short_name' => {
          'pattern' => true
        }
      }
    end

    # Adds wildcard searching
    collection_params['keyword'].concat('*') if collection_params.key?('keyword')

    # Retreive the collections from CMR, allowing a few additional parameters
    cmr_client.get_collections_by_post(collection_params, token).body
  end

  # Retreive only service implementation that have datasets assigned to them
  def get_service_implementations_with_datasets(params = {})
    # Retrieve all service entries for the current provider
    response = echo_client.get_service_entries_by_provider(echo_provider_token, current_provider_guid)

    if response.success?
      service_entries = Array.wrap(response.parsed_body.fetch('Item', [])).sort_by { |option| option['Name'].downcase }

      # Allow filtering the results by name (This is really slow and not recommended, but is a necessary feature)
      unless params.fetch('name', nil).blank?
        service_entries.select! { |s| s['Name'].downcase.start_with?(params['name'].downcase) }
      end

      # Filter down our list of all service entries that belong to the current provider to
      # just those with EntryType of SERVICE_IMPLEMENTATION and that have collections assigned to them
      service_entries.select! do |s|
        s['EntryType'] == 'SERVICE_IMPLEMENTATION' &&
          Array.wrap((s['TagGuids'] || {}).fetch('Item', [])).any? { |t| t.split('_', 3).include?('DATASET') }
      end

      service_entries
    else
      response.parsed_body
    end
  end

  # Retrieve collections from CMR based on concept ids assigned to a provided service interface
  def get_datasets_for_service_implementation(params = {})
    # service_interface_guid is not a permitted param for CMR but we need it for this call
    # so we'll use delete to pop the value from the params hash
    response = echo_client.get_service_entries(echo_provider_token, params.delete('service_interface_guid'))

    if response.success?
      service_entries = Array.wrap(response.parsed_body.fetch('Item', []))

      dataset_guids = service_entries.map do |service_entry|
        Array.wrap((service_entry['TagGuids'] || {}).fetch('Item', [])).group_by { |guid| guid.split('_', 3).first }['DATASET'] || []
      end

      if dataset_guids.any?
        # Merge any provided (permitted) params with the conecpt ids retrieved
        cmr_params = {
          concept_id: dataset_guids.flatten.map { |guid| guid.split('_', 3).last }
        }.merge(params)

        get_provider_collections(cmr_params)
      else
        {}
      end
    else
      response.parsed_body
    end
  end
end
