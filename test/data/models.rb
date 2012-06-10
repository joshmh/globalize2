#require 'ruby2ruby'
#require 'parse_tree'
#require 'parse_tree_extensions'
#require 'pp'

class PostTranslation < ActiveRecord::Base
  def existing_method ; end
end

class Post < ActiveRecord::Base
  translates :subject, :content
  validates_presence_of :subject
  named_scope :foobar, :conditions => { :title => "foobar" }
end

class Blog < ActiveRecord::Base
  has_many :posts, :order => 'id ASC'
end

class Parent < ActiveRecord::Base
end

class EarlyChild < Parent
end

class Parent < ActiveRecord::Base
  translates :content
end

class Child < Parent
end

class Comment < ActiveRecord::Base
  validates_presence_of :content
  belongs_to :post
end

class TranslatedComment < Comment
  translates :content
end

class UltraLongModelNameWithoutProper < ActiveRecord::Base
  translates :subject, :content
  validates_presence_of :subject
end

class Reloader < Parent
  after_create :do_reload

  def do_reload
    reload
  end
end

class Validatee < ActiveRecord::Base
  translates :string
end

class User < ActiveRecord::Base
  translates :name
  validates_presence_of :name, :email
end