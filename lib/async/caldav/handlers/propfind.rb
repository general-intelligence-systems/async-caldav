# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Propfind
        module_function

        def call(path:, storage:, user:, headers: {}, body: nil, **)
          depth = headers['depth'] || '1'
          propname = body&.include?('propname')
          build = propname ? :build_propname : :build_propfind

          col_path = path.ensure_trailing_slash
          collection = storage.get_collection(col_path.to_s)
          item_data = storage.get_item(path.to_s)

          # Non-existent deep path
          if !collection && !item_data && path.depth > 2
            return [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end

          xml = Protocol::Caldav::Multistatus.new.to_xml do |x|
            if collection
              col = Protocol::Caldav::Collection.new(
                path: col_path,
                type: collection[:type],
                displayname: collection[:displayname],
                description: collection[:description],
                color: collection[:color],
                props: collection[:props]
              )
              col.send(build, x)

              if depth != '0'
                storage.list_collections(col_path.to_s).each do |child_path, child_data|
                  child_p = Protocol::Caldav::Path.new(child_path, storage_class: storage)
                  child_col = Protocol::Caldav::Collection.new(
                    path: child_p,
                    type: child_data[:type],
                    displayname: child_data[:displayname],
                    description: child_data[:description],
                    color: child_data[:color],
                    props: child_data[:props]
                  )
                  child_col.send(build, x)
                end

                storage.list_items(col_path.to_s).each do |item_path, data|
                  item_p = Protocol::Caldav::Path.new(item_path, storage_class: storage)
                  item = Protocol::Caldav::Item.new(
                    path: item_p,
                    body: data[:body],
                    content_type: data[:content_type],
                    etag: data[:etag]
                  )
                  item.send(build, x)
                end
              end
            elsif item_data
              item = Protocol::Caldav::Item.new(
                path: path,
                body: item_data[:body],
                content_type: item_data[:content_type],
                etag: item_data[:etag]
              )
              item.send(build, x)
            else
              build_discovery(x, path, user)

              if depth != '0'
                storage.list_collections(col_path.to_s).each do |child_path, child_data|
                  child_p = Protocol::Caldav::Path.new(child_path, storage_class: storage)
                  child_col = Protocol::Caldav::Collection.new(
                    path: child_p,
                    type: child_data[:type],
                    displayname: child_data[:displayname],
                    description: child_data[:description],
                    color: child_data[:color],
                    props: child_data[:props]
                  )
                  child_col.send(build, x)
                end
              end
            end
          end

          [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
        end

        def build_discovery(xml, path, user)
          Protocol::Caldav::XmlBuilder.response(xml, href: path.to_s) do
            Protocol::Caldav::XmlBuilder.propstat_ok(xml) do
              xml.tag!("d:resourcetype") { xml.tag!("d:collection") }
              xml.tag!("d:current-user-principal") { xml.tag!("d:href", "/#{user}/") }
              xml.tag!("c:calendar-home-set") { xml.tag!("d:href", "/calendars/#{user}/") }
              xml.tag!("cr:addressbook-home-set") { xml.tag!("d:href", "/addressbooks/#{user}/") }
            end
          end
        end

        private_class_method :build_discovery
      end
    end
  end
end

test do
  def normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  describe "Async::Caldav::Handlers::Propfind" do
    def call(**opts)
      Async::Caldav::Handlers::Propfind.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "returns 207 with collection properties" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      status, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin', headers: { 'depth' => '0' })
      status.should.equal 207
      body[0].should.include 'Work'
      body[0].should.include 'calendar'
    end

    it "depth=1 includes child items" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      _, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin', headers: { 'depth' => '1' })
      body[0].should.include 'ev.ics'
    end

    it "returns 404 for deep non-existent path" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/calendars/admin/nope/deep/', s), storage: s, user: 'admin')
      status.should.equal 404
    end

    it "returns discovery info for shallow path" do
      s = Async::Caldav::Storage::Mock.new
      status, _, body = call(path: path('/', s), storage: s, user: 'admin')
      status.should.equal 207
      body[0].should.include 'current-user-principal'
      body[0].should.include '/admin/'
      body[0].should.include 'calendar-home-set'
    end

    it "propname request returns property names without values" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      propname_body = '<d:propfind xmlns:d="DAV:"><d:propname/></d:propfind>'
      status, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin',
        headers: { 'depth' => '1' }, body: propname_body)
      status.should.equal 207
      body[0].should.include '<d:resourcetype/>'
      body[0].should.include '<d:getetag/>'
    end

    it "allprop request returns all properties with values" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      allprop_body = '<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>'
      status, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin',
        headers: { 'depth' => '1' }, body: allprop_body)
      status.should.equal 207
      body[0].should.include 'displayname'
      body[0].should.include 'Work'
      body[0].should.include 'getetag'
    end

    it "returns item propfind for a single item" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      status, _, body = call(path: path('/calendars/admin/work/ev.ics', s), storage: s, user: 'admin')
      status.should.equal 207
      body[0].should.include 'getetag'
    end
  end
end
