# frozen_string_literal: true

require 'uri'

module Async
  module Caldav
    module Handlers
      module Move
        module_function

        def call(path:, storage:, headers: {}, **)
          destination = headers['destination']
          if destination
            to_path = URI.parse(destination).path
            overwrite = headers['overwrite'] != 'F'
            source = storage.get_item(path.to_s)
            if source
              existing = storage.get_item(to_path)
              if existing && !overwrite
                [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
              elsif !existing && uid_conflict?(
                path,
                to_path,
                source[:body],
                storage,
              )
                [409, { 'content-type' => 'text/plain' }, ['UID conflict']]
              else
                storage.move_item(path.to_s, to_path)
                if existing
                  [204, {}, ['']]
                else
                  [201, {}, ['']]
                end
              end
            else
              [404, { 'content-type' => 'text/plain' }, ['Not Found']]
            end
          else
            [400, { 'content-type' => 'text/plain' }, ['Missing Destination header']]
          end
        end

        # A UID may appear once per collection. The source item itself is
        # skipped, so moving an item back over its own path is not a clash.
        def uid_conflict?(path, to_path, body, storage)
          uid = extract_uid(body)
          if uid
            dest_col = Protocol::Caldav::Path.new(to_path).parent.to_s
            storage.list_items(dest_col).any? do |item_path, item_data|
              item_path != path.to_s && extract_uid(item_data[:body]) == uid
            end
          else
            false
          end
        end

        def extract_uid(body)
          if body
            match = body.match(/^UID:(.+)/i)
            match ? match[1].strip : nil
          else
            nil
          end
        end

        private_class_method :extract_uid, :uid_conflict?
      end
    end
  end
end

__END__

require_relative "../../caldav"

describe "Async::Caldav::Handlers::Move" do
  def call(**opts)
    Async::Caldav::Handlers::Move.call(**opts)
  end

  def path(p, s)
    Protocol::Caldav::Path.new(p, storage_class: s)
  end

  it "moves an item and returns 201" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    s.put_item('/cal/a.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    status, = call(
      path: path('/cal/a.ics', s), storage: s,
      headers: { 'destination' => 'http://localhost/cal/b.ics' }
    )
    status.should.equal 201
    s.get_item('/cal/a.ics').should.be.nil
    s.get_item('/cal/b.ics').should.not.be.nil
  end

  it "overwrites and returns 204" do
    s = Async::Caldav::Storage::Mock.new
    s.put_item('/cal/a.ics', 'A', 'text/calendar')
    s.put_item('/cal/b.ics', 'B', 'text/calendar')
    status, = call(
      path: path('/cal/a.ics', s), storage: s,
      headers: { 'destination' => 'http://localhost/cal/b.ics' }
    )
    status.should.equal 204
  end

  it "returns 400 without Destination header" do
    s = Async::Caldav::Storage::Mock.new
    status, = call(path: path('/cal/a.ics', s), storage: s, headers: {})
    status.should.equal 400
  end

  it "returns 404 when source missing" do
    s = Async::Caldav::Storage::Mock.new
    status, = call(
      path: path('/cal/nope.ics', s), storage: s,
      headers: { 'destination' => 'http://localhost/cal/b.ics' }
    )
    status.should.equal 404
  end

  it "returns 412 when Overwrite=F and destination exists" do
    s = Async::Caldav::Storage::Mock.new
    s.put_item('/cal/a.ics', 'A', 'text/calendar')
    s.put_item('/cal/b.ics', 'B', 'text/calendar')
    status, = call(
      path: path('/cal/a.ics', s), storage: s,
      headers: { 'destination' => 'http://localhost/cal/b.ics', 'overwrite' => 'F' }
    )
    status.should.equal 412
  end
end