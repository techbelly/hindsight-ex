# frozen_string_literal: true

module Hindsight
  Error = Class.new(StandardError)
end

require_relative "hindsight/project"
require_relative "hindsight/record"
require_relative "hindsight/recorder"
require_relative "hindsight/orderer"
require_relative "hindsight/graph"
require_relative "hindsight/line_editor"
require_relative "hindsight/slicer"
require_relative "hindsight/comments"
require_relative "hindsight/narrator"
require_relative "hindsight/builder"
