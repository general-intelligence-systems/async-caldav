# frozen_string_literal: true

module Async
  module Caldav
    module Handlers
      module Mkcol
        module_function

        # method: 'MKCALENDAR' or 'MKCOL'
        def call(path:, body:, storage:, method: 'MKCOL', resource_type: nil, **)
          col_path = path.ensure_trailing_slash

          if storage.collection_exists?(col_path.to_s)
            [405, { 'content-type' => 'text/plain' }, ['Collection already exists']]
          else
            if col_path.parent_exists?
              displayname = Protocol::Caldav::Xml.extract_value(body, 'displayname')
              description = Protocol::Caldav::Xml.extract_value(body, 'calendar-description')
              color = Protocol::Caldav::Xml.extract_value(body, 'calendar-color')
              if method == 'MKCALENDAR'
                type = :calendar
              elsif body && body.include?('addressbook')
                type = :addressbook
              else
                type = resource_type || :collection
              end
              storage.create_collection(col_path.to_s, type: type, displayname: displayname, description: description, color: color)
              [201, {}, ['']]
            else
              [409, { 'content-type' => 'text/plain' }, ['Parent collection does not exist']]
            end
          end
        end
      end
    end
  end
end

__END__

require_relative "../../caldav"

describe "Async::Caldav::Handlers::Mkcol" do
  def call(**opts)
    Async::Caldav::Handlers::Mkcol.call(**opts)
  end

  def path(p, s)
    Protocol::Caldav::Path.new(p, storage_class: s)
  end

  it "creates a calendar and returns 201" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/calendars/admin/')
    status, = call(
      path: path('/calendars/admin/work', s), storage: s,
      body: '<d:displayname>Work</d:displayname>', method: 'MKCALENDAR'
    )
    status.should.equal 201
    col = s.get_collection('/calendars/admin/work/')
    col[:type].should.equal :calendar
    col[:displayname].should.equal 'Work'
  end

  it "creates an addressbook via MKCOL" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/addressbooks/admin/')
    status, = call(
      path: path('/addressbooks/admin/contacts', s), storage: s,
      body: '<resourcetype><addressbook/></resourcetype>', method: 'MKCOL'
    )
    status.should.equal 201
    s.get_collection('/addressbooks/admin/contacts/')[:type].should.equal :addressbook
  end

  it "returns 405 if collection exists" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    status, = call(path: path('/cal/', s), storage: s, body: '', method: 'MKCALENDAR')
    status.should.equal 405
  end

  it "returns 409 if parent does not exist" do
    s = Async::Caldav::Storage::Mock.new
    status, = call(
      path: path('/calendars/admin/deep/nested/cal', s), storage: s,
      body: '', method: 'MKCALENDAR'
    )
    status.should.equal 409
  end
end