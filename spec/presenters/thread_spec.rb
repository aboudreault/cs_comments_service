require 'spec_helper'

describe ThreadPresenter do
  
  context "#to_hash" do

    before(:each) do 
      User.all.delete
      Content.all.delete

      course_id, commentable_id = ['foo', 'bar']

      @thread_no_responses = make_thread(
        create_test_user('author1'),
        'thread with no responses',
        course_id, commentable_id
      )

      @thread_one_empty_response = make_thread(
        create_test_user('author2'),
        'thread with one response',
        course_id, commentable_id
      )
      make_comment(create_test_user('author3'), @thread_one_empty_response, 'empty response')

      @thread_one_response = make_thread(
        create_test_user('author4'),
        'thread with one response and some comments',
        course_id, commentable_id
      )
      resp = make_comment(
        create_test_user('author5'),
        @thread_one_response,
        'a response'
      )
      make_comment(create_test_user('author6'), resp, 'first comment')
      make_comment(create_test_user('author7'), resp, 'second comment')
      make_comment(create_test_user('author8'), resp, 'third comment')

      @thread_ten_responses = make_thread(
        create_test_user('author9'),
        'thread with ten responses',
        course_id, commentable_id
      )
      (1..10).each do |n|
        resp = make_comment(create_test_user("author#{n+10}"), @thread_ten_responses, "response #{n}")
        (1..3).each do |n2|
          make_comment(create_test_user("author#{n+10}+#{n2}"), resp, "comment #{n+10}+#{n}")
        end
      end

      @threads_with_num_comments = [
        [@thread_no_responses, 0],
        [@thread_one_empty_response, 1],
        [@thread_one_response, 4],
        [@thread_ten_responses, 40]
      ]

      @reader = create_test_user('thread reader')
    end

    it "handles with_responses=false" do
      @threads_with_num_comments.each do |thread, num_comments|
        hash = ThreadPresenter.new(thread, @reader, false, num_comments, false).to_hash
        check_thread_result(@reader, thread, hash)
        ['children', 'resp_skip', 'resp_limit', 'resp_total'].each {|k| (hash.has_key? k).should be_false }
      end
    end

    it "handles with_responses=true" do
      @threads_with_num_comments.each do |thread, num_comments|
        hash = ThreadPresenter.new(thread, @reader, false, num_comments, false).to_hash true
        check_thread_result(@reader, thread, hash)
        check_thread_response_paging(thread, hash)
      end
    end

    it "handles skip with no limit" do
      @threads_with_num_comments.each do |thread, num_comments|
        [0, 1, 2, 9, 10, 11, 1000].each do |skip|
          hash = ThreadPresenter.new(thread, @reader, false, num_comments, false).to_hash true, skip
          check_thread_result(@reader, thread, hash)
          check_thread_response_paging(thread, hash, skip)
        end
      end
    end

    it "handles skip and limit" do
      @threads_with_num_comments.each do |thread, num_comments|
        [1, 2, 3, 9, 10, 11, 1000].each do |limit|
          [0, 1, 2, 9, 10, 11, 1000].each do |skip|
            hash = ThreadPresenter.new(thread, @reader, false, num_comments, false).to_hash true, skip, limit
            check_thread_result(@reader, thread, hash)
            check_thread_response_paging(thread, hash, skip, limit)
          end
        end
      end
    end

    it "fails with invalid arguments" do
      @threads_with_num_comments.each do |thread, num_comments|
        expect{ThreadPresenter.new(thread, @reader, false, num_comments, false).to_hash true, -1, nil}.to raise_error(ArgumentError)
        [-1, 0].each do |limit|
          expect{ThreadPresenter.new(thread, @reader, false, num_comments, false).to_hash true, 0, limit}.to raise_error(ArgumentError)
        end
      end
    end

  end

  context "#merge_comments_recursive" do

    before(:each) { @cid_seq = 10 }

    def stub_each_from_array(obj, ary)
      stub = obj.stub(:each)
      ary.each {|v| stub = stub.and_yield(v)}
      obj
    end

    def set_comment_results(thread, ary)
      # example usage:
      # c0 = make_comment()
      # c00 = make_comment(c0)
      # c01 = make_comment(c0)
      # c010 = make_comment(c01)
      # set_comment_results(thread, [c0, c00, c01, c010])

      # avoids an unrelated expecation error
      thread.stub(:endorsed?).and_return(true)
      rs = stub_each_from_array(double("rs"), ary)
      criteria = double("criteria")
      criteria.stub(:order_by).and_return(rs)
      # stub Content, not Comment, because that's the model we will be querying against
      Content.stub(:where).with({"comment_thread_id" => thread.id}).and_return(criteria)
    end

    def make_comment(parent=nil)
      c = Comment.new
      c.id = @cid_seq
      @cid_seq += 1
      c.parent_id = parent.nil? ? nil : parent.id
      c
    end

    it "nests comments in the correct order" do
      c0 = make_comment()
      c00 = make_comment(c0)
      c01 = make_comment(c0)
      c010 = make_comment(c01)

      pres = ThreadPresenter.new(nil, nil, nil, nil, nil)
      h = pres.merge_comments_recursive({}, [c0, c00, c01, c010])
      h["children"].size.should == 1 # c0
      h["children"][0]["id"].should == c0.id
      h["children"][0]["children"].size.should == 2 # c00, c01
      h["children"][0]["children"][0]["id"].should == c00.id
      h["children"][0]["children"][1]["id"].should == c01.id
      h["children"][0]["children"][1]["children"].size.should == 1 # c010
      h["children"][0]["children"][1]["children"][0]["id"].should == c010.id
    end

    it "handles orphaned child comments gracefully" do
      c0 = make_comment()
      c00 = make_comment(c0)
      c000 = make_comment(c00)
      c1 = make_comment()
      c10 = make_comment(c1)
      c11 = make_comment(c1)
      c111 = make_comment(c11)
      # lose c0 and c11 from result set.  their descendants should
      # be silently skipped over.

      pres = ThreadPresenter.new(nil, nil, nil, nil, nil)
      h = pres.merge_comments_recursive({}, [c00, c000, c1, c10, c111])
      h["children"].size.should == 1 # c1
      h["children"][0]["id"].should == c1.id
      h["children"][0]["children"].size.should == 1 # c10
      h["children"][0]["children"][0]["id"].should == c10.id
    end
  end
end

