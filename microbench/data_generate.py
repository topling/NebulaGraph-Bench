# Vendored from Nebula tests/bench/data_generate.py (Apache-2.0).
import random
import string


def insert_vertices(client, ns, batch_count, batch_size):
    resp = client.execute("USE " + ns)
    client.check_resp_succeeded(resp)
    for i in range(batch_count):
        query = generate_insert_student_vertex(batch_size, batch_size * i)
        resp = client.execute(query)
        client.check_resp_succeeded(resp)


def insert_edges(client, ns, batch_count, batch_size):
    resp = client.execute("USE " + ns)
    client.check_resp_succeeded(resp)
    for i in range(batch_count):
        query = generate_insert_likeness_edge(batch_size, batch_size * i)
        resp = client.execute(query)
        client.check_resp_succeeded(resp)


def random_string(string_length):
    letters = string.ascii_lowercase
    return "".join(random.choice(letters) for _ in range(string_length))


def random_students(size=100):
    students = []
    for _ in range(size):
        name = random_string(10)
        age = random.randint(1, 100)
        students.append((name, age))
    return students


def generate_insert_student_vertex(size, id_offset):
    students = random_students(size)
    length = len(students)
    query = "INSERT VERTEX person (name, age) VALUES "
    for i in range(length):
        student = students[i]
        query += '{0}:("{1}",{2})'.format(i + id_offset, student[0], student[1])
        if i < length - 1:
            query += ", "
    return query


def generate_insert_likeness_edge(length, id_offset):
    query = "INSERT EDGE like (likeness) VALUES "
    for i in range(length):
        first_id = random.randint(id_offset, length + id_offset)
        second_id = random.randint(id_offset, length + id_offset)
        query += "{0}->{1}:({2})".format(
            first_id, second_id, random.randint(100, 1000000)
        )
        if i < length - 1:
            query += ", "
    return query
